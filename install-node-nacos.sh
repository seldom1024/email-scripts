#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(pwd -P)"
DATA_DIR="$PROJECT_DIR/data"
IDENTITY_DIR="$DATA_DIR/cluster"
IDENTITY_DB="$IDENTITY_DIR/identity.db"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
REGISTRAR_FILE="$PROJECT_DIR/nacos/registrar.py"
IMAGE_NAME="seldomzq/email:latest"
CONTAINER_NAME="outlook-mail-reader"
readonly DEFAULT_PORT=5000
readonly MIN_PORT=1024
readonly MAX_PORT=65535
readonly HEALTHCHECK_TIMEOUT_SECONDS="${HEALTHCHECK_TIMEOUT_SECONDS:-300}"
readonly HEALTHCHECK_INTERVAL_SECONDS="${HEALTHCHECK_INTERVAL_SECONDS:-2}"
MASTER_URL=""
NODE_ID=""
MASTER_FINGERPRINT=""
NACOS_SERVER_URL=""
NACOS_SERVICE_NAME=""
NACOS_ADVERTISE_IP=""
NACOS_NAMESPACE_ID="public"
NACOS_GROUP_NAME="DEFAULT_GROUP"
NACOS_CLUSTER_NAME="DEFAULT"
NACOS_USERNAME="${NACOS_USERNAME:-}"
NACOS_PASSWORD="${NACOS_PASSWORD:-}"

log() { printf '[outlook-email-node] %s\n' "$*"; }
warn() { printf '[outlook-email-node] WARNING: %s\n' "$*" >&2; }
die() { printf '[outlook-email-node] ERROR: %s\n' "$*" >&2; exit 1; }

effective_uid() {
    if [[ -n "${INSTALLER_TEST_EUID:-}" ]]; then
        printf '%s\n' "$INSTALLER_TEST_EUID"
        return 0
    fi
    printf '%s\n' "${EUID:-$(id -u)}"
}

run_root() {
    if [[ "$(effective_uid)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die 'root privileges or sudo are required.'
    fi
}

docker_cmd() {
    if [[ "$(effective_uid)" -eq 0 ]]; then
        docker "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo docker "$@"
    else
        die 'Docker access requires root privileges or sudo.'
    fi
}

compose_cmd() {
    docker_cmd compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

set_project_dir() {
    local directory="$1"
    mkdir -p "$directory"
    PROJECT_DIR="$(cd -- "$directory" && pwd -P)"
    DATA_DIR="$PROJECT_DIR/data"
    IDENTITY_DIR="$DATA_DIR/cluster"
    IDENTITY_DB="$IDENTITY_DIR/identity.db"
    COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
    ENV_FILE="$PROJECT_DIR/.env"
    REGISTRAR_FILE="$PROJECT_DIR/nacos/registrar.py"
}

validate_container_name() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
        || die 'Container name must start with a letter or digit and use only letters, digits, dot, dash, or underscore.'
}

set_container_name() {
    local name="$1"
    validate_container_name "$name"
    CONTAINER_NAME="$name"
}

validate_image_version() {
    local version="$1"
    [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
        || die 'Image version must use letters, digits, dot, dash, or underscore.'
}

set_image_version() {
    local version="$1"
    validate_image_version "$version"
    IMAGE_NAME="seldomzq/email:$version"
}

validate_nacos_url() {
    local value="$1"
    [[ "$value" =~ ^https?://[^/?#[:space:]]+(/nacos)?/?$ ]] \
        || die 'Nacos URL must be http(s)://host[:port] with an optional /nacos path and no query or fragment.'
}

normalize_nacos_url() {
    local value="$1"
    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done
    printf '%s\n' "$value"
}

validate_ipv4() {
    local value="$1" octet
    local -a octets
    IFS='.' read -r -a octets <<<"$value"
    ((${#octets[@]} == 4)) || die 'advertise IP must be an explicit IPv4 address.'
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] \
            || die 'advertise IP must contain four decimal IPv4 octets.'
        ((10#$octet <= 255)) || die 'advertise IP contains an octet greater than 255.'
    done
    [[ "$value" != '0.0.0.0' ]] || die 'advertise IP cannot be the unspecified address.'
    ((10#${octets[0]} != 127)) || die 'advertise IP cannot be a loopback address.'
    ((10#${octets[0]} < 224)) || die 'advertise IP cannot be multicast, reserved, or broadcast.'
}

validate_nacos_identifier() {
    local label="$1" value="$2"
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$ ]] \
        || die "Nacos $label must use letters, digits, dot, dash, underscore, or colon."
}

validate_nacos_credentials() {
    if [[ -z "$NACOS_USERNAME" && -z "$NACOS_PASSWORD" ]]; then
        return 0
    fi
    [[ -n "$NACOS_USERNAME" && -n "$NACOS_PASSWORD" ]] \
        || die 'NACOS_USERNAME and NACOS_PASSWORD must be provided together.'
    validate_env_value NACOS_USERNAME "$NACOS_USERNAME"
    validate_env_value NACOS_PASSWORD "$NACOS_PASSWORD"
}

write_compose_file() {
    mkdir -p "$PROJECT_DIR"
    cat >"$COMPOSE_FILE" <<'COMPOSE'
services:
  outlook-mail-replica:
    image: __OUTLOOK_EMAIL_IMAGE__
    container_name: __OUTLOOK_EMAIL_CONTAINER__
    ports:
      - "${OUTLOOK_EMAIL_PORT:-5000}:5000"
    volumes:
      - ./data:/app/data
    environment:
      - NODE_ROLE=replica
      - MASTER_URL=${MASTER_URL}
      - SECRET_KEY=${SECRET_KEY}
    restart: unless-stopped

  nacos-registrar:
    image: python:3.12-alpine
    depends_on:
      - outlook-mail-replica
    command: ["python", "/app/registrar.py"]
    volumes:
      - ./nacos/registrar.py:/app/registrar.py:ro
    environment:
      - NACOS_SERVER_URL=${NACOS_SERVER_URL}
      - NACOS_SERVICE_NAME=${NACOS_SERVICE_NAME}
      - NACOS_ADVERTISE_IP=${NACOS_ADVERTISE_IP}
      - NACOS_ADVERTISE_PORT=${OUTLOOK_EMAIL_PORT:-5000}
      - NACOS_NAMESPACE_ID=${NACOS_NAMESPACE_ID:-public}
      - NACOS_GROUP_NAME=${NACOS_GROUP_NAME:-DEFAULT_GROUP}
      - NACOS_CLUSTER_NAME=${NACOS_CLUSTER_NAME:-DEFAULT}
      - NACOS_USERNAME=${NACOS_USERNAME:-}
      - NACOS_PASSWORD=${NACOS_PASSWORD:-}
      - REPLICA_READY_URL=http://outlook-mail-replica:5000/health/ready
      - PYTHONUNBUFFERED=1
      - PYTHONDONTWRITEBYTECODE=1
    read_only: true
    restart: unless-stopped
    stop_grace_period: 25s
COMPOSE
    sed -i "s|__OUTLOOK_EMAIL_IMAGE__|$IMAGE_NAME|g" "$COMPOSE_FILE"
    sed -i "s|__OUTLOOK_EMAIL_CONTAINER__|$CONTAINER_NAME|g" "$COMPOSE_FILE"
}

detect_os() {
    local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
    [[ -r "$os_release_file" ]] || die "Cannot read $os_release_file."
    # shellcheck disable=SC1090
    . "$os_release_file"
    local distro_id="${ID:-}"
    distro_id="${distro_id//$'\r'/}"
    case "${distro_id,,}" in
        ubuntu|debian|centos|rhel|rocky|almalinux|amzn)
            printf '%s\n' "${distro_id,,}"
            ;;
        *)
            die "Unsupported Linux distribution: ${distro_id:-unknown}. Supported: Ubuntu, Debian, CentOS, RHEL, Rocky Linux, AlmaLinux, Amazon Linux."
            ;;
    esac
}

require_linux_systemd() {
    [[ "$(uname -s)" == 'Linux' ]] || die 'This installer supports Linux servers only.'
    command -v systemctl >/dev/null 2>&1 || die 'systemctl is required; non-systemd environments are not supported.'
}

require_privileges() {
    if [[ "$(effective_uid)" -eq 0 ]]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || die 'Run as root or install sudo before running this installer.'
    sudo -v || die 'Unable to obtain sudo privileges.'
}

apt_install_docker() {
    local distro="$1"
    local codename architecture
    codename="$(. "${OS_RELEASE_FILE:-/etc/os-release}"; printf '%s' "${VERSION_CODENAME:-}")"
    [[ -n "$codename" ]] || die 'Could not determine the Debian/Ubuntu release codename.'
    architecture="$(dpkg --print-architecture)"

    run_root apt-get update
    run_root apt-get install -y ca-certificates curl openssl gnupg
    run_root install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$distro/gpg" \
        | gpg --dearmor \
        | run_root tee /etc/apt/keyrings/docker.gpg >/dev/null
    run_root chmod a+r /etc/apt/keyrings/docker.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$architecture" "$distro" "$codename" \
        | run_root tee /etc/apt/sources.list.d/docker.list >/dev/null
    run_root apt-get update
    run_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

rpm_install_docker() {
    local package_manager="$1"
    if [[ "$package_manager" == 'dnf' ]]; then
        run_root dnf install -y dnf-plugins-core ca-certificates curl openssl
        run_root dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        run_root dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        run_root yum install -y yum-utils ca-certificates curl openssl
        run_root yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        run_root yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
}

amazon_linux_package_manager() {
    if command -v dnf >/dev/null 2>&1; then
        printf '%s\n' dnf
    elif command -v yum >/dev/null 2>&1; then
        printf '%s\n' yum
    else
        die 'Neither dnf nor yum is available on this Amazon Linux system.'
    fi
}

amazon_linux_install_docker() {
    local package_manager
    package_manager="$(amazon_linux_package_manager)"
    run_root "$package_manager" install -y ca-certificates curl openssl docker
}

install_docker() {
    local distro="$1"
    case "$distro" in
        ubuntu|debian)
            apt_install_docker "$distro"
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf >/dev/null 2>&1; then
                rpm_install_docker dnf
            elif command -v yum >/dev/null 2>&1; then
                rpm_install_docker yum
            else
                die 'Neither dnf nor yum is available on this CentOS-family system.'
            fi
            ;;
        amzn)
            amazon_linux_install_docker
            ;;
        *)
            die "Unsupported distribution: $distro"
            ;;
    esac
}

ensure_host_tools() {
    local distro="$1"
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    ((${#missing[@]} == 0)) && return 0

    case "$distro" in
        ubuntu|debian)
            run_root apt-get update
            run_root apt-get install -y ca-certificates "${missing[@]}"
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf >/dev/null 2>&1; then
                run_root dnf install -y ca-certificates "${missing[@]}"
            elif command -v yum >/dev/null 2>&1; then
                run_root yum install -y ca-certificates "${missing[@]}"
            else
                die 'Neither dnf nor yum is available to install required host tools.'
            fi
            ;;
        amzn)
            local package_manager
            package_manager="$(amazon_linux_package_manager)"
            run_root "$package_manager" install -y ca-certificates "${missing[@]}"
            ;;
        *)
            die "Unsupported distribution: $distro"
            ;;
    esac
}

ensure_docker() {
    local distro="$1"
    if ! command -v docker >/dev/null 2>&1; then
        install_docker "$distro"
    fi
    if ! docker_cmd info >/dev/null 2>&1; then
        run_root systemctl enable --now docker.service
    fi
    docker_cmd info >/dev/null 2>&1 || die 'Docker daemon is not available after startup.'
}

ensure_compose() {
    local distro="$1"
    if docker_cmd compose version >/dev/null 2>&1; then
        return 0
    fi
    case "$distro" in
        ubuntu|debian)
            run_root apt-get update
            run_root apt-get install -y docker-compose-plugin
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf >/dev/null 2>&1; then
                run_root dnf install -y docker-compose-plugin
            elif command -v yum >/dev/null 2>&1; then
                run_root yum install -y docker-compose-plugin
            else
                die 'Neither dnf nor yum is available to install Docker Compose Plugin.'
            fi
            ;;
        *)
            die "Unsupported distribution: $distro"
            ;;
    esac
    docker_cmd compose version >/dev/null 2>&1 || die 'Docker Compose v2 plugin is not available after installation.'
}

is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ((10#$port >= MIN_PORT && 10#$port <= MAX_PORT))
}

port_is_used_by_own_container() {
    local port="$1"
    docker_cmd ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Ports}}' 2>/dev/null \
        | grep -Eq "(^|[, ])(0\.0\.0\.0:|\[::\]:)?${port}->5000/tcp"
}

is_port_available() {
    local port="$1"
    is_valid_port "$port" || return 1
    port_is_used_by_own_container "$port" && return 0
    if command -v ss >/dev/null 2>&1; then
        ! ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
    elif command -v lsof >/dev/null 2>&1; then
        ! lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q .
    else
        ! docker_cmd ps --format '{{.Ports}}' 2>/dev/null | grep -Eq "(^|[, ])(0\.0\.0\.0:|\[::\]:)?${port}->"
    fi
}

choose_port() {
    local configured_port="${1:-$DEFAULT_PORT}"
    local explicit="${2:-0}"
    local candidate
    if [[ "$explicit" == '1' ]] && ! is_valid_port "$configured_port"; then
        die "Host port must be an integer between $MIN_PORT and $MAX_PORT."
    fi
    if is_port_available "$configured_port"; then
        printf '%s\n' "$configured_port"
        return 0
    fi

    if [[ "$explicit" == '1' ]]; then
        die "Host port $configured_port is already in use. Choose another port."
    fi

    warn "Host port $configured_port is already in use."
    while true; do
        read -r -p "Enter an unused host port ($MIN_PORT-$MAX_PORT): " candidate
        if ! is_valid_port "$candidate"; then
            warn 'Port must be an integer between 1024 and 65535.'
            continue
        fi
        if is_port_available "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        warn "Host port $candidate is also in use."
    done
}

read_env_value() {
    local file="$1"
    local key="$2"
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
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 1
    awk -v key="$key" '
        BEGIN { assignment = "^[[:space:]]*(export[[:space:]]+)?" key "[[:space:]]*=" }
        $0 ~ assignment {
            found = 1
            exit
        }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

validate_nacos_service_name() {
    validate_nacos_identifier service "$1"
}

prompt_required_value() {
    local variable_name="$1"
    local label="$2"
    local env_key="$3"
    local validator="$4"
    local current default_value='' entered candidate validation_output
    current="${!variable_name}"

    if [[ -n "$current" ]]; then
        "$validator" "$current"
        return 0
    fi
    if [[ -n "$env_key" ]]; then
        default_value="$(read_env_value "$ENV_FILE" "$env_key" || true)"
    fi

    while true; do
        if [[ -n "$default_value" ]]; then
            printf '%s [%s]: ' "$label" "$default_value" >&2
        else
            printf '%s: ' "$label" >&2
        fi
        IFS= read -r entered || die "输入已结束，未能读取${label}。"
        candidate="$entered"
        [[ -n "$candidate" ]] || candidate="$default_value"
        if [[ -z "$candidate" ]]; then
            warn "${label}不能为空。"
            continue
        fi
        if validation_output="$("$validator" "$candidate" 2>&1)"; then
            printf -v "$variable_name" '%s' "$candidate"
            return 0
        fi
        warn "${validation_output#*ERROR: }"
    done
}

resolve_install_inputs() {
    prompt_required_value MASTER_URL '主节点地址' MASTER_URL validate_master_url
    MASTER_URL="$(normalize_master_url "$MASTER_URL")"
    prompt_required_value NODE_ID '节点 ID' '' validate_node_id
    prompt_required_value MASTER_FINGERPRINT '主节点指纹' '' validate_master_fingerprint
    prompt_required_value NACOS_SERVER_URL 'Nacos 地址' NACOS_SERVER_URL validate_nacos_url
    NACOS_SERVER_URL="$(normalize_nacos_url "$NACOS_SERVER_URL")"
    prompt_required_value NACOS_SERVICE_NAME 'Nacos 服务名' NACOS_SERVICE_NAME validate_nacos_service_name
    prompt_required_value NACOS_ADVERTISE_IP '注册 IP' NACOS_ADVERTISE_IP validate_ipv4
}

resolve_nacos_credentials() {
    local existing_username existing_password validation_output
    local username_key_present=0 password_key_present=0
    if [[ -n "$NACOS_USERNAME" || -n "$NACOS_PASSWORD" ]]; then
        validate_nacos_credentials
        return 0
    fi
    existing_username="$(read_env_value "$ENV_FILE" NACOS_USERNAME || true)"
    existing_password="$(read_env_value "$ENV_FILE" NACOS_PASSWORD || true)"
    env_file_has_key "$ENV_FILE" NACOS_USERNAME && username_key_present=1
    env_file_has_key "$ENV_FILE" NACOS_PASSWORD && password_key_present=1
    if ((username_key_present || password_key_present)); then
        ((username_key_present && password_key_present)) \
            || die 'NACOS_USERNAME and NACOS_PASSWORD must be provided together.'
        NACOS_USERNAME="$existing_username"
        NACOS_PASSWORD="$existing_password"
        validate_nacos_credentials
        return 0
    fi

    while true; do
        printf 'Nacos 用户名（直接回车表示无需认证）: ' >&2
        IFS= read -r NACOS_USERNAME \
            || die '输入已结束，未能读取 Nacos 用户名。'
        NACOS_PASSWORD=''
        if [[ -z "$NACOS_USERNAME" ]]; then
            return 0
        fi
        if ! validation_output="$(validate_env_value NACOS_USERNAME "$NACOS_USERNAME" 2>&1)"; then
            warn "${validation_output#*ERROR: }"
            NACOS_USERNAME=''
            continue
        fi

        while true; do
            printf 'Nacos 密码: ' >&2
            if ! IFS= read -r -s NACOS_PASSWORD; then
                printf '\n' >&2
                die '输入已结束，未能读取 Nacos 密码。'
            fi
            printf '\n' >&2
            if [[ -z "$NACOS_PASSWORD" ]]; then
                warn 'Nacos 密码不能为空。'
                continue
            fi
            if validation_output="$(validate_nacos_credentials 2>&1)"; then
                return 0
            fi
            warn "${validation_output#*ERROR: }"
            NACOS_PASSWORD=''
        done
    done
}

upsert_env_var() {
    local file="$1"
    local key="$2"
    local value="$3"
    local directory temporary
    directory="$(dirname -- "$file")"
    mkdir -p "$directory"
    temporary="$(mktemp "$directory/.env.tmp.XXXXXX")"
    if [[ -f "$file" ]]; then
        awk -v key="$key" -v replacement="$key=$value" '
            BEGIN { assignment = "^[[:space:]]*(export[[:space:]]+)?" key "[[:space:]]*=" }
            $0 ~ assignment {
                if (!updated) print replacement
                updated = 1
                next
            }
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

generate_secret_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    elif [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    else
        die 'No secure random source is available for SECRET_KEY.'
    fi
}

write_registrar_file() {
    local directory temporary
    directory="$(dirname -- "$REGISTRAR_FILE")"
    mkdir -p "$directory"
    temporary="$(mktemp "$directory/.registrar.py.tmp.XXXXXX")"
    cat >"$temporary" <<'PYTHON'
#!/usr/bin/env python3
import ipaddress
import json
import logging
import os
import signal
import threading
import urllib.error
import urllib.parse
import urllib.request


LOG = logging.getLogger("nacos-registrar")


def required_env(name):
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(f"{name} is required")
    return value


def positive_float(name, default):
    value = float(os.environ.get(name, default))
    if value <= 0:
        raise ValueError(f"{name} must be greater than zero")
    return value


def normalize_api_root(server_url):
    parsed = urllib.parse.urlsplit(server_url.rstrip("/"))
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise ValueError("NACOS_SERVER_URL must be an HTTP(S) URL")
    path = parsed.path.rstrip("/")
    if path in ("", "/"):
        path = "/nacos"
    elif path != "/nacos":
        raise ValueError("NACOS_SERVER_URL path must be empty or /nacos")
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))


class Config:
    def __init__(self):
        self.api_root = normalize_api_root(required_env("NACOS_SERVER_URL"))
        self.service_name = required_env("NACOS_SERVICE_NAME")
        address = ipaddress.ip_address(required_env("NACOS_ADVERTISE_IP"))
        if address.version != 4:
            raise ValueError("NACOS_ADVERTISE_IP must be IPv4")
        self.ip = str(address)
        self.port = int(required_env("NACOS_ADVERTISE_PORT"))
        if not 1 <= self.port <= 65535:
            raise ValueError("NACOS_ADVERTISE_PORT is out of range")
        self.namespace_id = os.environ.get("NACOS_NAMESPACE_ID", "public")
        self.group_name = os.environ.get("NACOS_GROUP_NAME", "DEFAULT_GROUP")
        self.cluster_name = os.environ.get("NACOS_CLUSTER_NAME", "DEFAULT")
        self.username = os.environ.get("NACOS_USERNAME", "")
        self.password = os.environ.get("NACOS_PASSWORD", "")
        if bool(self.username) != bool(self.password):
            raise ValueError(
                "NACOS_USERNAME and NACOS_PASSWORD must be provided together"
            )
        self.ready_url = required_env("REPLICA_READY_URL")
        self.heartbeat_interval = positive_float(
            "NACOS_HEARTBEAT_INTERVAL", "5"
        )
        self.readiness_interval = positive_float(
            "NACOS_READINESS_INTERVAL", "2"
        )
        self.retry_initial = positive_float("NACOS_RETRY_INITIAL", "1")
        self.retry_max = positive_float("NACOS_RETRY_MAX", "30")
        self.http_timeout = positive_float("NACOS_HTTP_TIMEOUT", "5")
        if self.retry_initial > self.retry_max:
            raise ValueError("NACOS_RETRY_INITIAL cannot exceed NACOS_RETRY_MAX")


class NacosRegistrar:
    def __init__(self, config):
        self.config = config
        self.access_token = None
        self.stop_event = threading.Event()
        self.registered = False

    def stop(self, _signum=None, _frame=None):
        self.stop_event.set()

    def _perform(self, method, path, params):
        url = f"{self.config.api_root}{path}"
        data = None
        headers = {"Accept": "application/json"}
        if method in ("GET", "DELETE"):
            query = urllib.parse.urlencode(params)
            if query:
                url = f"{url}?{query}"
        else:
            data = urllib.parse.urlencode(params).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        request = urllib.request.Request(
            url, data=data, headers=headers, method=method
        )
        with urllib.request.urlopen(
            request, timeout=self.config.http_timeout
        ) as response:
            return response.read()

    def _login(self):
        body = self._perform(
            "POST",
            "/nacos/v1/auth/users/login",
            {
                "username": self.config.username,
                "password": self.config.password,
            },
        )
        payload = json.loads(body.decode("utf-8"))
        token = payload.get("accessToken")
        if not token:
            raise RuntimeError("Nacos login response did not include accessToken")
        self.access_token = token

    def _request(self, method, path, params):
        for attempt in range(2):
            request_params = dict(params)
            if self.config.username:
                if not self.access_token:
                    self._login()
                request_params["accessToken"] = self.access_token
            try:
                return self._perform(method, path, request_params)
            except urllib.error.HTTPError as error:
                if (
                    error.code in (401, 403)
                    and self.config.username
                    and attempt == 0
                ):
                    error.close()
                    self.access_token = None
                    continue
                raise
        raise RuntimeError("Nacos authentication retry was exhausted")

    def _instance_params(self):
        return {
            "serviceName": self.config.service_name,
            "groupName": self.config.group_name,
            "clusterName": self.config.cluster_name,
            "namespaceId": self.config.namespace_id,
            "ip": self.config.ip,
            "port": str(self.config.port),
            "ephemeral": "true",
        }

    def register(self):
        params = self._instance_params()
        params.update(
            {
                "weight": "1.0",
                "enabled": "true",
                "healthy": "true",
            }
        )
        self._request("POST", "/nacos/v1/ns/instance", params)
        self.registered = True
        LOG.info(
            "Registered %s at %s:%s",
            self.config.service_name,
            self.config.ip,
            self.config.port,
        )

    def heartbeat(self):
        beat = {
            "serviceName": self.config.service_name,
            "groupName": self.config.group_name,
            "cluster": self.config.cluster_name,
            "ip": self.config.ip,
            "port": self.config.port,
            "weight": 1.0,
            "ephemeral": True,
        }
        body = self._request(
            "PUT",
            "/nacos/v1/ns/instance/beat",
            {
                "serviceName": self.config.service_name,
                "groupName": self.config.group_name,
                "namespaceId": self.config.namespace_id,
                "ephemeral": "true",
                "beat": json.dumps(beat, separators=(",", ":")),
            },
        )
        try:
            response = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            response = None
        if isinstance(response, dict) and str(response.get("code")) == "20404":
            self.registered = False
            self.register()

    def deregister(self):
        self._request(
            "DELETE", "/nacos/v1/ns/instance", self._instance_params()
        )
        self.registered = False
        LOG.info(
            "Deregistered %s at %s:%s",
            self.config.service_name,
            self.config.ip,
            self.config.port,
        )

    def replica_is_ready(self):
        request = urllib.request.Request(
            self.config.ready_url, method="GET"
        )
        try:
            with urllib.request.urlopen(
                request, timeout=self.config.http_timeout
            ) as response:
                return 200 <= response.status < 300
        except (urllib.error.URLError, TimeoutError):
            return False

    @staticmethod
    def _error_label(error):
        if isinstance(error, urllib.error.HTTPError):
            return f"HTTP {error.code}"
        return type(error).__name__

    def run(self):
        retry_delay = self.config.retry_initial
        try:
            while not self.stop_event.is_set():
                if not self.replica_is_ready():
                    if self.registered:
                        try:
                            self.deregister()
                            retry_delay = self.config.retry_initial
                        except Exception as error:
                            LOG.warning(
                                "Deregistration failed (%s); retrying",
                                self._error_label(error),
                            )
                            self.stop_event.wait(retry_delay)
                            retry_delay = min(
                                retry_delay * 2, self.config.retry_max
                            )
                            continue
                    self.stop_event.wait(self.config.readiness_interval)
                    continue

                if not self.registered:
                    try:
                        self.register()
                        retry_delay = self.config.retry_initial
                    except Exception as error:
                        LOG.warning(
                            "Registration failed (%s); retrying",
                            self._error_label(error),
                        )
                        self.stop_event.wait(retry_delay)
                        retry_delay = min(
                            retry_delay * 2, self.config.retry_max
                        )
                        continue

                try:
                    self.heartbeat()
                    retry_delay = self.config.retry_initial
                    self.stop_event.wait(self.config.heartbeat_interval)
                except Exception as error:
                    LOG.warning(
                        "Heartbeat failed (%s); retrying",
                        self._error_label(error),
                    )
                    self.stop_event.wait(retry_delay)
                    retry_delay = min(retry_delay * 2, self.config.retry_max)
        finally:
            if self.registered:
                try:
                    self.deregister()
                except Exception as error:
                    LOG.warning(
                        "Final deregistration failed (%s)",
                        self._error_label(error),
                    )


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    registrar = NacosRegistrar(Config())
    signal.signal(signal.SIGTERM, registrar.stop)
    signal.signal(signal.SIGINT, registrar.stop)
    registrar.run()


if __name__ == "__main__":
    main()
PYTHON
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$REGISTRAR_FILE"
    chmod 600 "$REGISTRAR_FILE"
}

validate_env_value() {
    local key="$1"
    local value="$2"
    [[ -n "$value" ]] || die "$key cannot be empty."
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$key cannot contain newlines."
    [[ "$value" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]] || die "$key contains characters unsafe for the generated .env file."
}

validate_master_url() {
    [[ "$1" =~ ^https?://[^[:space:]?#]+$ ]] || die 'master URL must be http or https without query or fragment.'
}

normalize_master_url() {
    local value="$1"
    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done
    printf '%s\n' "$value"
}

validate_node_id() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'node id must use letters, digits, dot, dash, or underscore.'
}

validate_master_fingerprint() {
    [[ "$1" =~ ^SHA256:[0-9A-Fa-f]{64}$ ]] || die 'master fingerprint must look like SHA256:<64 hex chars>.'
}

ensure_identity_directory() {
    mkdir -p "$IDENTITY_DIR"
    chmod 700 "$IDENTITY_DIR"
}

chmod_identity_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    chmod 600 "$file"
}

identity_exists() {
    [[ -s "$IDENTITY_DB" ]]
}

run_cluster_cli_enroll() {
    local secret_key="$1"
    docker_cmd run --rm -i \
        -e "SECRET_KEY=$secret_key" \
        -v "$DATA_DIR:/app/data" \
        --entrypoint python \
        "$IMAGE_NAME" \
        -m outlook_web.cluster.cli enroll \
        --master "$MASTER_URL" \
        --node-id "$NODE_ID" \
        --master-fingerprint "$MASTER_FINGERPRINT" \
        --identity-dir /app/data/cluster
}

validate_existing_identity() {
    local secret_key="$1"
    run_cluster_cli_enroll "$secret_key" </dev/null >/dev/null || die 'Existing replica identity conflicts with the requested node.'
}

prepare_env() {
    local configured_port configured_secret
    local secret_key
    configured_port="$(read_env_value "$ENV_FILE" OUTLOOK_EMAIL_PORT || true)"
    configured_secret="$(read_env_value "$ENV_FILE" SECRET_KEY || true)"
    [[ -n "$configured_port" ]] || configured_port="$DEFAULT_PORT"
    if [[ -n "$configured_secret" ]]; then
        secret_key="$configured_secret"
    else
        secret_key="$(generate_secret_key)"
    fi

    validate_env_value MASTER_URL "$MASTER_URL"
    validate_env_value SECRET_KEY "$secret_key"
    NACOS_SERVER_URL="$(normalize_nacos_url "$NACOS_SERVER_URL")"
    validate_nacos_url "$NACOS_SERVER_URL"
    validate_nacos_identifier service "$NACOS_SERVICE_NAME"
    validate_ipv4 "$NACOS_ADVERTISE_IP"
    validate_nacos_identifier namespace "$NACOS_NAMESPACE_ID"
    validate_nacos_identifier group "$NACOS_GROUP_NAME"
    validate_nacos_identifier cluster "$NACOS_CLUSTER_NAME"
    validate_nacos_credentials
    validate_env_value NACOS_SERVER_URL "$NACOS_SERVER_URL"
    validate_env_value NACOS_SERVICE_NAME "$NACOS_SERVICE_NAME"
    validate_env_value NACOS_ADVERTISE_IP "$NACOS_ADVERTISE_IP"
    validate_env_value NACOS_NAMESPACE_ID "$NACOS_NAMESPACE_ID"
    validate_env_value NACOS_GROUP_NAME "$NACOS_GROUP_NAME"
    validate_env_value NACOS_CLUSTER_NAME "$NACOS_CLUSTER_NAME"
    upsert_env_var "$ENV_FILE" OUTLOOK_EMAIL_PORT "$configured_port"
    upsert_env_var "$ENV_FILE" MASTER_URL "$MASTER_URL"
    upsert_env_var "$ENV_FILE" SECRET_KEY "$secret_key"
    upsert_env_var "$ENV_FILE" NACOS_SERVER_URL "$NACOS_SERVER_URL"
    upsert_env_var "$ENV_FILE" NACOS_SERVICE_NAME "$NACOS_SERVICE_NAME"
    upsert_env_var "$ENV_FILE" NACOS_ADVERTISE_IP "$NACOS_ADVERTISE_IP"
    upsert_env_var "$ENV_FILE" NACOS_NAMESPACE_ID "$NACOS_NAMESPACE_ID"
    upsert_env_var "$ENV_FILE" NACOS_GROUP_NAME "$NACOS_GROUP_NAME"
    upsert_env_var "$ENV_FILE" NACOS_CLUSTER_NAME "$NACOS_CLUSTER_NAME"
    upsert_env_var "$ENV_FILE" NACOS_USERNAME "$NACOS_USERNAME"
    upsert_env_var "$ENV_FILE" NACOS_PASSWORD "$NACOS_PASSWORD"
    chmod 600 "$ENV_FILE"
}

pull_image() {
    compose_cmd pull
}

enroll_node() {
    local secret_key
    secret_key="$(read_env_value "$ENV_FILE" SECRET_KEY || true)"
    [[ -n "$secret_key" ]] || die 'SECRET_KEY is missing from .env.'
    ensure_identity_directory
    if identity_exists; then
        validate_existing_identity "$secret_key"
        log 'Reusing existing replica identity.'
        return 0
    fi
    printf 'Enrollment token: ' >&2
    read -r -s ENROLLMENT_TOKEN
    printf '\n' >&2
    [[ -n "$ENROLLMENT_TOKEN" ]] || die 'Enrollment token is required.'
    printf '%s\n' "$ENROLLMENT_TOKEN" | run_cluster_cli_enroll "$secret_key"
    [[ -s "$IDENTITY_DB" ]] || die "Replica enrollment did not create $IDENTITY_DB."
    chmod_identity_file "$IDENTITY_DB"
}

refresh_and_start() {
    pull_image || return $?
    enroll_node || return $?
    compose_cmd up -d || return $?
}

show_failure_diagnostics() {
    compose_cmd ps || true
    compose_cmd logs --tail 100 outlook-mail-replica nacos-registrar || true
}

wait_for_ready() {
    local port="$1"
    local deadline=$((SECONDS + HEALTHCHECK_TIMEOUT_SECONDS))
    while ((SECONDS < deadline)); do
        if curl -fsS --max-time 5 "http://127.0.0.1:${port}/health/ready" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$HEALTHCHECK_INTERVAL_SECONDS"
    done
    return 1
}

print_summary() {
    local port="$1"
    printf '\nReplica installation completed.\n'
    printf 'URL: http://SERVER_IP:%s\n' "$port"
    printf 'Container: %s\n' "$CONTAINER_NAME"
    printf 'Nacos service: %s (namespace=%s, group=%s, cluster=%s)\n' \
        "$NACOS_SERVICE_NAME" "$NACOS_NAMESPACE_ID" "$NACOS_GROUP_NAME" "$NACOS_CLUSTER_NAME"
    printf 'Nacos endpoint: %s:%s\n' "$NACOS_ADVERTISE_IP" "$port"
    printf 'Identity: %s\n' "$IDENTITY_DB"
    printf 'Environment: %s\n' "$ENV_FILE"
}

usage() {
    cat <<'USAGE'
Usage: install-node-nacos.sh [--master URL] [--node-id ID] [--master-fingerprint FINGERPRINT] [--nacos-url URL] [--nacos-service NAME] [--advertise-ip IPv4] [options]

Install or repair Docker and Docker Compose, persist replica-local configuration,
enroll the replica when needed, and start it with a Nacos registration sidecar.

Omitted required values are requested interactively. Existing deployment values
from .env are shown as defaults where available; press Enter to reuse them.

The default install directory is the current working directory.
--v VERSION selects the email image tag (default: latest).
--n CONTAINER_NAME selects the replica container name (default: outlook-mail-reader).
--p PORT selects the host port mapped to container port 5000 (default: 5000).
--nacos-url URL sets the Nacos server URL (optional /nacos suffix; prompted if omitted).
--nacos-service NAME sets the Nacos service name (prompted if omitted).
--advertise-ip IPv4 sets the exact address registered in Nacos (prompted if omitted).
--nacos-namespace ID sets the namespace (default: public).
--nacos-group NAME sets the group (default: DEFAULT_GROUP).
--nacos-cluster NAME sets the cluster (default: DEFAULT).
Set NACOS_USERNAME and NACOS_PASSWORD together in the process environment for
unattended authenticated installs. Otherwise credentials are reused from .env or
requested interactively; press Enter at the username prompt for no authentication.
--project-dir is retained as an alias for --install-dir.
USAGE
}

main() {
    local project_dir_arg="" distro configured_port selected_port requested_port=""
    local port_arg_set=0
    while (($# > 0)); do
        case "$1" in
            --v)
                [[ $# -ge 2 ]] || die '--v requires a value.'
                set_image_version "$2"
                shift 2
                ;;
            --n)
                [[ $# -ge 2 ]] || die '--n requires a value.'
                set_container_name "$2"
                shift 2
                ;;
            --p)
                [[ $# -ge 2 ]] || die '--p requires a value.'
                requested_port="$2"
                port_arg_set=1
                shift 2
                ;;
            --master)
                [[ $# -ge 2 ]] || die '--master requires a value.'
                MASTER_URL="$2"
                shift 2
                ;;
            --node-id)
                [[ $# -ge 2 ]] || die '--node-id requires a value.'
                NODE_ID="$2"
                shift 2
                ;;
            --master-fingerprint)
                [[ $# -ge 2 ]] || die '--master-fingerprint requires a value.'
                MASTER_FINGERPRINT="$2"
                shift 2
                ;;
            --nacos-url)
                [[ $# -ge 2 ]] || die '--nacos-url requires a value.'
                NACOS_SERVER_URL="$2"
                shift 2
                ;;
            --nacos-service)
                [[ $# -ge 2 ]] || die '--nacos-service requires a value.'
                NACOS_SERVICE_NAME="$2"
                shift 2
                ;;
            --advertise-ip)
                [[ $# -ge 2 ]] || die '--advertise-ip requires a value.'
                NACOS_ADVERTISE_IP="$2"
                shift 2
                ;;
            --nacos-namespace)
                [[ $# -ge 2 ]] || die '--nacos-namespace requires a value.'
                NACOS_NAMESPACE_ID="$2"
                shift 2
                ;;
            --nacos-group)
                [[ $# -ge 2 ]] || die '--nacos-group requires a value.'
                NACOS_GROUP_NAME="$2"
                shift 2
                ;;
            --nacos-cluster)
                [[ $# -ge 2 ]] || die '--nacos-cluster requires a value.'
                NACOS_CLUSTER_NAME="$2"
                shift 2
                ;;
            --project-dir|--install-dir)
                [[ $# -ge 2 ]] || die "$1 requires a path."
                project_dir_arg="$2"
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    if [[ -n "$project_dir_arg" ]]; then
        set_project_dir "$project_dir_arg"
    fi
    resolve_install_inputs
    validate_nacos_identifier namespace "$NACOS_NAMESPACE_ID"
    validate_nacos_identifier group "$NACOS_GROUP_NAME"
    validate_nacos_identifier cluster "$NACOS_CLUSTER_NAME"
    resolve_nacos_credentials

    require_linux_systemd
    require_privileges
    distro="$(detect_os)"
    ensure_docker "$distro"
    ensure_host_tools "$distro"
    ensure_compose "$distro"

    mkdir -p "$DATA_DIR"
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    write_registrar_file
    write_compose_file
    configured_port="$(read_env_value "$ENV_FILE" OUTLOOK_EMAIL_PORT || true)"
    if ((port_arg_set)); then
        configured_port="$requested_port"
    fi
    [[ -n "$configured_port" ]] || configured_port="$DEFAULT_PORT"
    selected_port="$(choose_port "$configured_port" "$port_arg_set")"
    prepare_env
    upsert_env_var "$ENV_FILE" OUTLOOK_EMAIL_PORT "$selected_port"
    if refresh_and_start; then
        :
    else
        local start_status=$?
        show_failure_diagnostics
        return "$start_status"
    fi
    wait_for_ready "$selected_port" || die 'Replica started but did not become ready.'
    print_summary "$selected_port"
}

if [[ "${INSTALLER_LIB_ONLY:-0}" != '1' ]]; then
    main "$@"
fi
