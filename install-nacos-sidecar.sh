#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly DEFAULT_PROJECT_DIR='./mail-nacos-sidecar'
readonly DEFAULT_NACOS_SERVICE_NAME='mail-cluster'
readonly DEFAULT_NACOS_NAMESPACE_ID='public'
readonly DEFAULT_NACOS_GROUP_NAME='DEFAULT_GROUP'
readonly DEFAULT_NACOS_CLUSTER_NAME='DEFAULT'
readonly DEFAULT_ADVERTISE_PORT=5000
readonly DEFAULT_READY_URL='http://127.0.0.1:5000/health/ready'
readonly MIN_PORT=1024
readonly MAX_PORT=65535

PROJECT_DIR=''
DATA_DIR=''
COMPOSE_FILE=''
ENV_FILE=''
REGISTRAR_FILE=''
NACOS_SERVER_URL="${NACOS_SERVER_URL:-}"
NACOS_SERVICE_NAME="${NACOS_SERVICE_NAME:-$DEFAULT_NACOS_SERVICE_NAME}"
NACOS_ADVERTISE_IP="${NACOS_ADVERTISE_IP:-}"
NACOS_ADVERTISE_PORT="${NACOS_ADVERTISE_PORT:-$DEFAULT_ADVERTISE_PORT}"
REPLICA_READY_URL="${REPLICA_READY_URL:-$DEFAULT_READY_URL}"
NACOS_NAMESPACE_ID="${NACOS_NAMESPACE_ID:-$DEFAULT_NACOS_NAMESPACE_ID}"
NACOS_GROUP_NAME="${NACOS_GROUP_NAME:-$DEFAULT_NACOS_GROUP_NAME}"
NACOS_CLUSTER_NAME="${NACOS_CLUSTER_NAME:-$DEFAULT_NACOS_CLUSTER_NAME}"
NACOS_USERNAME="${NACOS_USERNAME:-}"
NACOS_PASSWORD="${NACOS_PASSWORD:-}"

log() { printf '[install-nacos-sidecar] %s\n' "$*"; }
warn() { printf '[install-nacos-sidecar] WARNING: %s\n' "$*" >&2; }
die() { printf '[install-nacos-sidecar] ERROR: %s\n' "$*" >&2; exit 1; }

set_project_dir() {
    local directory="$1"
    mkdir -p "$directory"
    PROJECT_DIR="$(cd -- "$directory" && pwd -P)"
    DATA_DIR="$PROJECT_DIR/data"
    COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
    ENV_FILE="$PROJECT_DIR/.env"
    REGISTRAR_FILE="$PROJECT_DIR/nacos/registrar.py"
}

set_project_dir "$DEFAULT_PROJECT_DIR"

read_env_value() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    awk -v key="$key" '
        BEGIN { assignment = "^[[:space:]]*(export[[:space:]]+)?" key "[[:space:]]*=" }
        $0 ~ assignment {
            value = $0
            sub(assignment, "", value)
            sub(/\r$/, "", value)
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            first = substr(value, 1, 1)
            last = substr(value, length(value), 1)
            if (length(value) >= 2 && ((first == "\"" && last == "\"") || (first == "\047" && last == "\047"))) {
                value = substr(value, 2, length(value) - 2)
            }
            print value
            exit
        }
    ' "$file"
}

env_file_has_key() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    awk -v key="$key" 'BEGIN { a="^[[:space:]]*(export[[:space:]]+)?" key "[[:space:]]*=" } $0 ~ a { found=1; exit } END { exit(found ? 0 : 1) }' "$file"
}

upsert_env_var() {
    local file="$1" key="$2" value="$3" directory temporary
    directory="$(dirname -- "$file")"
    mkdir -p "$directory"
    temporary="$(mktemp "$directory/.env.tmp.XXXXXX")"
    if [[ -f "$file" ]]; then
        awk -v key="$key" -v replacement="$key=$value" '
            BEGIN { a="^[[:space:]]*(export[[:space:]]+)?" key "[[:space:]]*=" }
            $0 ~ a { if (!updated) print replacement; updated=1; next }
            { print }
            END { if (!updated) print replacement }
        ' "$file" >"$temporary"
    else
        printf '%s\n' "$key=$value" >"$temporary"
    fi
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$file"
    chmod 600 "$file"
}

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    elif [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    else
        die 'No secure random source is available.'
    fi
}

validate_nacos_url() {
    [[ "$1" =~ ^https?://[^/:[:space:]?#]+(:[0-9]+)?(/nacos)?/?$ ]] \
        || die 'Nacos URL must be http(s)://host[:port] with optional /nacos and no query or fragment.'
}

validate_ready_url() {
    [[ "$1" =~ ^https?://[^[:space:]?#]+$ ]] \
        || die 'Readiness URL must use http(s) without query or fragment.'
}

validate_nacos_identifier() {
    local label="$1" value="$2"
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
        || die "$label must use letters, digits, dot, dash, or underscore."
}

validate_ipv4() {
    local value="$1" octet
    local -a octets
    IFS='.' read -r -a octets <<<"$value"
    ((${#octets[@]} == 4)) || die 'Registration IP must be an explicit IPv4 address.'
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || die 'Registration IP must contain four IPv4 octets.'
        ((10#$octet <= 255)) || die 'Registration IP contains an octet greater than 255.'
    done
    [[ "$value" != '0.0.0.0' ]] || die 'Registration IP cannot be 0.0.0.0.'
    ((10#${octets[0]} != 127)) || die 'Registration IP cannot be loopback.'
    ((10#${octets[0]} < 224)) || die 'Registration IP cannot be multicast or reserved.'
}

validate_port() {
    local label="$1" value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || die "$label port must be an integer."
    ((10#$value >= MIN_PORT && 10#$value <= MAX_PORT)) || die "$label port must be between $MIN_PORT and $MAX_PORT."
}

validate_env_value() {
    local key="$1" value="$2"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$key cannot contain newlines."
    [[ "$value" =~ ^[A-Za-z0-9_@%+=:,./~!\$*()-]+$ ]] || die "$key contains characters unsafe for .env."
}

validate_nacos_credentials() {
    if [[ -z "$NACOS_USERNAME" && -z "$NACOS_PASSWORD" ]]; then return 0; fi
    [[ -n "$NACOS_USERNAME" && -n "$NACOS_PASSWORD" ]] || die 'NACOS_USERNAME and NACOS_PASSWORD must be provided together.'
    validate_env_value NACOS_USERNAME "$NACOS_USERNAME"
    validate_env_value NACOS_PASSWORD "$NACOS_PASSWORD"
}

prompt_required() {
    local prompt="$1" variable="$2" validator="$3" entered
    while true; do
        printf '%s: ' "$prompt" >&2
        IFS= read -r entered || die "$prompt is required."
        if [[ -n "$entered" ]] && "$validator" "$entered" >/dev/null 2>&1; then
            printf -v "$variable" '%s' "$entered"
            return 0
        fi
        warn "$prompt is invalid."
    done
}

resolve_nacos_credentials() {
    local stored_user stored_password user_key=0 password_key=0
    if [[ -n "$NACOS_USERNAME" || -n "$NACOS_PASSWORD" ]]; then validate_nacos_credentials; return 0; fi
    stored_user="$(read_env_value "$ENV_FILE" NACOS_USERNAME || true)"
    stored_password="$(read_env_value "$ENV_FILE" NACOS_PASSWORD || true)"
    env_file_has_key "$ENV_FILE" NACOS_USERNAME && user_key=1
    env_file_has_key "$ENV_FILE" NACOS_PASSWORD && password_key=1
    if ((user_key || password_key)); then
        ((user_key && password_key)) || die 'NACOS_USERNAME and NACOS_PASSWORD must be provided together.'
        NACOS_USERNAME="$stored_user"; NACOS_PASSWORD="$stored_password"
        validate_nacos_credentials
        return 0
    fi
    printf 'Nacos username (blank for no authentication): ' >&2
    IFS= read -r NACOS_USERNAME || die 'Nacos username input ended unexpectedly.'
    if [[ -z "$NACOS_USERNAME" ]]; then NACOS_PASSWORD=''; return 0; fi
    printf 'Nacos password: ' >&2
    IFS= read -r -s NACOS_PASSWORD || { printf '\n' >&2; die 'Nacos password input ended unexpectedly.'; }
    printf '\n' >&2
    validate_nacos_credentials
}

resolve_inputs() {
    local stored
    stored="$(read_env_value "$ENV_FILE" NACOS_SERVER_URL || true)"; [[ -n "$NACOS_SERVER_URL" ]] || NACOS_SERVER_URL="$stored"
    [[ -n "$NACOS_SERVER_URL" ]] || prompt_required 'Nacos 地址' NACOS_SERVER_URL validate_nacos_url
    stored="$(read_env_value "$ENV_FILE" NACOS_SERVICE_NAME || true)"; [[ "$NACOS_SERVICE_NAME" == "$DEFAULT_NACOS_SERVICE_NAME" && -n "$stored" ]] && NACOS_SERVICE_NAME="$stored"; [[ -n "$NACOS_SERVICE_NAME" ]] || NACOS_SERVICE_NAME="$DEFAULT_NACOS_SERVICE_NAME"
    stored="$(read_env_value "$ENV_FILE" NACOS_ADVERTISE_IP || true)"; [[ -n "$NACOS_ADVERTISE_IP" ]] || NACOS_ADVERTISE_IP="$stored"
    [[ -n "$NACOS_ADVERTISE_IP" ]] || prompt_required '注册ip' NACOS_ADVERTISE_IP validate_ipv4
    stored="$(read_env_value "$ENV_FILE" NACOS_ADVERTISE_PORT || true)"; [[ "$NACOS_ADVERTISE_PORT" == "$DEFAULT_ADVERTISE_PORT" && -n "$stored" ]] && NACOS_ADVERTISE_PORT="$stored"
    stored="$(read_env_value "$ENV_FILE" REPLICA_READY_URL || true)"; [[ "$REPLICA_READY_URL" == "$DEFAULT_READY_URL" && -n "$stored" ]] && REPLICA_READY_URL="$stored"
    stored="$(read_env_value "$ENV_FILE" NACOS_NAMESPACE_ID || true)"; [[ "$NACOS_NAMESPACE_ID" == "$DEFAULT_NACOS_NAMESPACE_ID" && -n "$stored" ]] && NACOS_NAMESPACE_ID="$stored"
    stored="$(read_env_value "$ENV_FILE" NACOS_GROUP_NAME || true)"; [[ "$NACOS_GROUP_NAME" == "$DEFAULT_NACOS_GROUP_NAME" && -n "$stored" ]] && NACOS_GROUP_NAME="$stored"
    stored="$(read_env_value "$ENV_FILE" NACOS_CLUSTER_NAME || true)"; [[ "$NACOS_CLUSTER_NAME" == "$DEFAULT_NACOS_CLUSTER_NAME" && -n "$stored" ]] && NACOS_CLUSTER_NAME="$stored"
    resolve_nacos_credentials
    validate_nacos_url "$NACOS_SERVER_URL"
    validate_nacos_identifier service "$NACOS_SERVICE_NAME"
    validate_ipv4 "$NACOS_ADVERTISE_IP"
    validate_port advertise "$NACOS_ADVERTISE_PORT"
    validate_ready_url "$REPLICA_READY_URL"
    validate_nacos_identifier namespace "$NACOS_NAMESPACE_ID"
    validate_nacos_identifier group "$NACOS_GROUP_NAME"
    validate_nacos_identifier cluster "$NACOS_CLUSTER_NAME"
}

prepare_env() {
    local stored
    [[ -n "$NACOS_SERVER_URL" ]] || NACOS_SERVER_URL="$(read_env_value "$ENV_FILE" NACOS_SERVER_URL || true)"
    stored="$(read_env_value "$ENV_FILE" NACOS_SERVICE_NAME || true)"; if [[ -z "$NACOS_SERVICE_NAME" || "$NACOS_SERVICE_NAME" == "$DEFAULT_NACOS_SERVICE_NAME" ]]; then [[ -n "$stored" ]] && NACOS_SERVICE_NAME="$stored"; fi
    [[ -n "$NACOS_SERVICE_NAME" ]] || NACOS_SERVICE_NAME="$DEFAULT_NACOS_SERVICE_NAME"
    [[ -n "$NACOS_ADVERTISE_IP" ]] || NACOS_ADVERTISE_IP="$(read_env_value "$ENV_FILE" NACOS_ADVERTISE_IP || true)"
    [[ -n "$NACOS_ADVERTISE_PORT" ]] || NACOS_ADVERTISE_PORT="$DEFAULT_ADVERTISE_PORT"
    [[ -n "$REPLICA_READY_URL" ]] || REPLICA_READY_URL="$DEFAULT_READY_URL"
    stored="$(read_env_value "$ENV_FILE" NACOS_NAMESPACE_ID || true)"; if [[ -z "$NACOS_NAMESPACE_ID" || "$NACOS_NAMESPACE_ID" == "$DEFAULT_NACOS_NAMESPACE_ID" ]]; then [[ -n "$stored" ]] && NACOS_NAMESPACE_ID="$stored"; fi; [[ -n "$NACOS_NAMESPACE_ID" ]] || NACOS_NAMESPACE_ID="$DEFAULT_NACOS_NAMESPACE_ID"
    stored="$(read_env_value "$ENV_FILE" NACOS_GROUP_NAME || true)"; if [[ -z "$NACOS_GROUP_NAME" || "$NACOS_GROUP_NAME" == "$DEFAULT_NACOS_GROUP_NAME" ]]; then [[ -n "$stored" ]] && NACOS_GROUP_NAME="$stored"; fi; [[ -n "$NACOS_GROUP_NAME" ]] || NACOS_GROUP_NAME="$DEFAULT_NACOS_GROUP_NAME"
    stored="$(read_env_value "$ENV_FILE" NACOS_CLUSTER_NAME || true)"; if [[ -z "$NACOS_CLUSTER_NAME" || "$NACOS_CLUSTER_NAME" == "$DEFAULT_NACOS_CLUSTER_NAME" ]]; then [[ -n "$stored" ]] && NACOS_CLUSTER_NAME="$stored"; fi; [[ -n "$NACOS_CLUSTER_NAME" ]] || NACOS_CLUSTER_NAME="$DEFAULT_NACOS_CLUSTER_NAME"
    stored="$(read_env_value "$ENV_FILE" NACOS_ADVERTISE_PORT || true)"; [[ "$NACOS_ADVERTISE_PORT" == "$DEFAULT_ADVERTISE_PORT" && -n "$stored" ]] && NACOS_ADVERTISE_PORT="$stored"
    validate_nacos_url "$NACOS_SERVER_URL"; validate_nacos_identifier service "$NACOS_SERVICE_NAME"; validate_ipv4 "$NACOS_ADVERTISE_IP"; validate_port advertise "$NACOS_ADVERTISE_PORT"; validate_ready_url "$REPLICA_READY_URL"; validate_nacos_identifier namespace "$NACOS_NAMESPACE_ID"; validate_nacos_identifier group "$NACOS_GROUP_NAME"; validate_nacos_identifier cluster "$NACOS_CLUSTER_NAME"; validate_nacos_credentials
    mkdir -p "$PROJECT_DIR"
    upsert_env_var "$ENV_FILE" NACOS_SERVER_URL "${NACOS_SERVER_URL%/}"
    upsert_env_var "$ENV_FILE" NACOS_SERVICE_NAME "$NACOS_SERVICE_NAME"
    upsert_env_var "$ENV_FILE" NACOS_ADVERTISE_IP "$NACOS_ADVERTISE_IP"
    upsert_env_var "$ENV_FILE" NACOS_ADVERTISE_PORT "$NACOS_ADVERTISE_PORT"
    upsert_env_var "$ENV_FILE" REPLICA_READY_URL "$REPLICA_READY_URL"
    upsert_env_var "$ENV_FILE" NACOS_NAMESPACE_ID "$NACOS_NAMESPACE_ID"
    upsert_env_var "$ENV_FILE" NACOS_GROUP_NAME "$NACOS_GROUP_NAME"
    upsert_env_var "$ENV_FILE" NACOS_CLUSTER_NAME "$NACOS_CLUSTER_NAME"
    upsert_env_var "$ENV_FILE" NACOS_USERNAME "$NACOS_USERNAME"
    upsert_env_var "$ENV_FILE" NACOS_PASSWORD "$NACOS_PASSWORD"
}

write_registrar_file() {
    local directory temporary
    directory="$(dirname -- "$REGISTRAR_FILE")"; mkdir -p "$directory"; temporary="$(mktemp "$directory/.registrar.py.tmp.XXXXXX")"
    cat >"$temporary" <<'PYTHON'
#!/usr/bin/env python3
import ipaddress, json, logging, os, signal, threading, time, urllib.error, urllib.parse, urllib.request

LOG = logging.getLogger("nacos-registrar")

def required(name):
    value = os.environ.get(name, "")
    if not value: raise ValueError(f"{name} is required")
    return value

def positive(name, default):
    value = float(os.environ.get(name, default))
    if value <= 0: raise ValueError(f"{name} must be greater than zero")
    return value

class Config:
    def __init__(self):
        parsed = urllib.parse.urlsplit(required("NACOS_SERVER_URL").rstrip("/"))
        if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.query or parsed.fragment: raise ValueError("NACOS_SERVER_URL is invalid")
        if parsed.path not in ("", "/nacos"): raise ValueError("NACOS_SERVER_URL path must be empty or /nacos")
        self.api_root = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "/nacos", "", ""))
        self.service_name = required("NACOS_SERVICE_NAME")
        address = ipaddress.ip_address(required("NACOS_ADVERTISE_IP"))
        if address.version != 4: raise ValueError("NACOS_ADVERTISE_IP must be IPv4")
        self.ip = str(address); self.port = int(required("NACOS_ADVERTISE_PORT"))
        if not 1 <= self.port <= 65535: raise ValueError("NACOS_ADVERTISE_PORT is out of range")
        self.namespace_id = os.environ.get("NACOS_NAMESPACE_ID", "public")
        self.group_name = os.environ.get("NACOS_GROUP_NAME", "DEFAULT_GROUP")
        self.cluster_name = os.environ.get("NACOS_CLUSTER_NAME", "DEFAULT")
        self.username = os.environ.get("NACOS_USERNAME", ""); self.password = os.environ.get("NACOS_PASSWORD", "")
        if bool(self.username) != bool(self.password): raise ValueError("NACOS_USERNAME and NACOS_PASSWORD must be provided together")
        self.ready_url = required("REPLICA_READY_URL")
        self.heartbeat_interval = positive("NACOS_HEARTBEAT_INTERVAL", "5")
        self.readiness_interval = positive("NACOS_READINESS_INTERVAL", "2")
        self.retry_initial = positive("NACOS_RETRY_INITIAL", "1")
        self.retry_max = positive("NACOS_RETRY_MAX", "30")
        self.http_timeout = positive("NACOS_HTTP_TIMEOUT", "5")

class Registrar:
    def __init__(self, config): self.config=config; self.token=None; self.stop_event=threading.Event(); self.registered=False
    def stop(self, *_): self.stop_event.set()
    def perform(self, method, path, params):
        url=f"{self.config.api_root}{path}"; data=None; headers={"Accept":"application/json"}
        if method in ("GET", "DELETE"):
            query=urllib.parse.urlencode(params); url=f"{url}?{query}" if query else url
        else: data=urllib.parse.urlencode(params).encode(); headers["Content-Type"]="application/x-www-form-urlencoded"
        request=urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(request, timeout=self.config.http_timeout) as response: return response.read()
    def login(self):
        body=self.perform("POST", "/v1/auth/users/login", {"username":self.config.username,"password":self.config.password})
        payload=json.loads(body.decode()); self.token=payload.get("accessToken")
        if not self.token: raise RuntimeError("Nacos login response did not include accessToken")
    def request(self, method, path, params):
        for attempt in range(2):
            request_params=dict(params)
            if self.config.username:
                if not self.token: self.login()
                request_params["accessToken"]=self.token
            try: return self.perform(method, path, request_params)
            except urllib.error.HTTPError as error:
                if error.code in (401,403) and self.config.username and attempt == 0: error.close(); self.token=None; continue
                raise
        raise RuntimeError("Nacos authentication retry was exhausted")
    def instance_params(self): return {"serviceName":self.config.service_name,"groupName":self.config.group_name,"clusterName":self.config.cluster_name,"namespaceId":self.config.namespace_id,"ip":self.config.ip,"port":str(self.config.port),"ephemeral":"true"}
    def register(self):
        params=self.instance_params(); params.update(weight="1.0", enabled="true", healthy="true"); self.request("POST", "/v1/ns/instance", params); self.registered=True; LOG.info("Registered %s at %s:%s", self.config.service_name, self.config.ip, self.config.port)
    def heartbeat(self):
        beat={"serviceName":self.config.service_name,"groupName":self.config.group_name,"cluster":self.config.cluster_name,"ip":self.config.ip,"port":self.config.port,"weight":1.0,"ephemeral":True}
        body=self.request("PUT", "/v1/ns/instance/beat", {"serviceName":self.config.service_name,"groupName":self.config.group_name,"namespaceId":self.config.namespace_id,"ephemeral":"true","beat":json.dumps(beat,separators=(",",":"))})
        try: payload=json.loads(body.decode())
        except (UnicodeDecodeError,json.JSONDecodeError): payload=None
        if isinstance(payload,dict) and str(payload.get("code")) == "20404": self.registered=False; self.register()
    def deregister(self): self.request("DELETE", "/v1/ns/instance", self.instance_params()); self.registered=False; LOG.info("Deregistered %s", self.config.service_name)
    def ready(self):
        try:
            request=urllib.request.Request(self.config.ready_url, method="GET")
            with urllib.request.urlopen(request, timeout=self.config.http_timeout) as response: return 200 <= response.status < 300
        except (urllib.error.URLError, TimeoutError): return False
    def run(self):
        retry=self.config.retry_initial
        try:
            while not self.stop_event.is_set():
                if not self.ready():
                    if self.registered:
                        try: self.deregister(); retry=self.config.retry_initial
                        except Exception: self.stop_event.wait(retry); retry=min(retry*2,self.config.retry_max); continue
                    self.stop_event.wait(self.config.readiness_interval); continue
                if not self.registered:
                    try: self.register(); retry=self.config.retry_initial
                    except Exception as error: LOG.warning("Registration failed (%s); retrying", type(error).__name__); self.stop_event.wait(retry); retry=min(retry*2,self.config.retry_max); continue
                try: self.heartbeat(); retry=self.config.retry_initial; self.stop_event.wait(self.config.heartbeat_interval)
                except Exception as error: LOG.warning("Heartbeat failed (%s); retrying", type(error).__name__); self.stop_event.wait(retry); retry=min(retry*2,self.config.retry_max)
        finally:
            if self.registered:
                try: self.deregister()
                except Exception as error: LOG.warning("Final deregistration failed (%s)", type(error).__name__)

def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    registrar=Registrar(Config()); signal.signal(signal.SIGTERM, registrar.stop); signal.signal(signal.SIGINT, registrar.stop); registrar.run()

if __name__ == "__main__": main()
PYTHON
    chmod 600 "$temporary"; mv -f -- "$temporary" "$REGISTRAR_FILE"; chmod 600 "$REGISTRAR_FILE"
}

write_compose_file() {
    local temporary
    mkdir -p "$DATA_DIR"; temporary="$(mktemp "$PROJECT_DIR/.compose.tmp.XXXXXX")"
    cat >"$temporary" <<'COMPOSE'
services:
  nacos-registrar:
    image: python:3.12-alpine
    network_mode: host
    command: ["python", "/app/registrar.py"]
    volumes:
      - ./nacos/registrar.py:/app/registrar.py:ro
    environment:
      - NACOS_SERVER_URL=${NACOS_SERVER_URL}
      - NACOS_SERVICE_NAME=${NACOS_SERVICE_NAME}
      - NACOS_ADVERTISE_IP=${NACOS_ADVERTISE_IP}
      - NACOS_ADVERTISE_PORT=${NACOS_ADVERTISE_PORT}
      - REPLICA_READY_URL=${REPLICA_READY_URL}
      - NACOS_NAMESPACE_ID=${NACOS_NAMESPACE_ID}
      - NACOS_GROUP_NAME=${NACOS_GROUP_NAME}
      - NACOS_CLUSTER_NAME=${NACOS_CLUSTER_NAME}
      - NACOS_USERNAME=${NACOS_USERNAME}
      - NACOS_PASSWORD=${NACOS_PASSWORD}
      - PYTHONUNBUFFERED=1
      - PYTHONDONTWRITEBYTECODE=1
    restart: unless-stopped
COMPOSE
    chmod 600 "$temporary"; mv -f -- "$temporary" "$COMPOSE_FILE"; chmod 600 "$COMPOSE_FILE"
}

require_linux() { [[ "$(uname -s)" == Linux ]] || die 'This installer supports Linux only.'; }
require_privileges() { [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0; command -v sudo >/dev/null 2>&1 || die 'Root privileges or sudo are required.'; sudo -v || die 'Unable to obtain sudo privileges.'; }
docker_cmd() { [[ "${EUID:-$(id -u)}" -eq 0 ]] && docker "$@" || sudo docker "$@"; }
compose_cmd() { docker_cmd compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }
ensure_docker() { command -v docker >/dev/null 2>&1 || die 'Docker is not installed.'; docker_cmd info >/dev/null 2>&1 || die 'Docker daemon is not available.'; }
ensure_compose() { docker_cmd compose version >/dev/null 2>&1 || die 'Docker Compose v2 is not available.'; }
check_ready_endpoint() { curl -fsS --connect-timeout 5 --max-time 5 "$REPLICA_READY_URL" >/dev/null 2>&1 || die "Business readiness endpoint is unavailable: $REPLICA_READY_URL"; }
validate_compose() { compose_cmd config -q; }
refresh_and_start() { validate_compose && compose_cmd pull && compose_cmd up -d; }
show_service_status() { compose_cmd ps; }

redact_sensitive_text() {
    local text="$1" secret
    for secret in "$NACOS_USERNAME" "$NACOS_PASSWORD"; do [[ -n "$secret" ]] && text="${text//"$secret"/[REDACTED]}"; done
    printf '%s' "$text"
}

show_failure_diagnostics() {
    local output
    output="$(compose_cmd ps 2>&1 || true)"; redact_sensitive_text "$output" >&2
    output="$(compose_cmd logs --tail 100 nacos-registrar 2>&1 || true)"; redact_sensitive_text "$output" >&2
}

usage() {
    cat <<'USAGE'
Usage: install-nacos-sidecar.sh [options]

Options:
  --project-dir PATH
  --nacos-url URL
  --nacos-service NAME
  --advertise-ip IPV4
  --advertise-port PORT
  --ready-url URL
  --nacos-namespace ID
  --nacos-group NAME
  --nacos-cluster NAME
  --nacos-username USER
  -h, --help

NACOS_PASSWORD is read from the environment or hidden interactive input.
USAGE
}

main() {
    local project_dir_arg=''
    while (($#)); do
        case "$1" in
            --project-dir) [[ $# -ge 2 ]] || die '--project-dir requires a value.'; project_dir_arg="$2"; shift 2 ;;
            --nacos-url) [[ $# -ge 2 ]] || die '--nacos-url requires a value.'; NACOS_SERVER_URL="$2"; shift 2 ;;
            --nacos-service) [[ $# -ge 2 ]] || die '--nacos-service requires a value.'; NACOS_SERVICE_NAME="$2"; shift 2 ;;
            --advertise-ip) [[ $# -ge 2 ]] || die '--advertise-ip requires a value.'; NACOS_ADVERTISE_IP="$2"; shift 2 ;;
            --advertise-port) [[ $# -ge 2 ]] || die '--advertise-port requires a value.'; NACOS_ADVERTISE_PORT="$2"; shift 2 ;;
            --ready-url) [[ $# -ge 2 ]] || die '--ready-url requires a value.'; REPLICA_READY_URL="$2"; shift 2 ;;
            --nacos-namespace) [[ $# -ge 2 ]] || die '--nacos-namespace requires a value.'; NACOS_NAMESPACE_ID="$2"; shift 2 ;;
            --nacos-group) [[ $# -ge 2 ]] || die '--nacos-group requires a value.'; NACOS_GROUP_NAME="$2"; shift 2 ;;
            --nacos-cluster) [[ $# -ge 2 ]] || die '--nacos-cluster requires a value.'; NACOS_CLUSTER_NAME="$2"; shift 2 ;;
            --nacos-username) [[ $# -ge 2 ]] || die '--nacos-username requires a value.'; NACOS_USERNAME="$2"; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    [[ -n "$project_dir_arg" ]] && set_project_dir "$project_dir_arg"
    resolve_inputs
    prepare_env
    check_ready_endpoint
    require_linux; require_privileges; ensure_docker; ensure_compose
    write_registrar_file; write_compose_file
    if ! refresh_and_start; then show_failure_diagnostics; die 'Nacos Sidecar failed to start.'; fi
    show_service_status
    log "Sidecar project: $PROJECT_DIR"
    log "Registered service: $NACOS_SERVICE_NAME at $NACOS_ADVERTISE_IP:$NACOS_ADVERTISE_PORT"
}

if [[ "${INSTALLER_LIB_ONLY:-0}" != 1 ]]; then main "$@"; fi
