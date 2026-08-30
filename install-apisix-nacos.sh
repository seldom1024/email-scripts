#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

PROJECT_DIR="$(pwd -P)"
DATA_DIR="$PROJECT_DIR/data"
ETCD_DATA_DIR="$DATA_DIR/etcd"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
APISIX_CONFIG_FILE="$PROJECT_DIR/config.yaml"
DASHBOARD_CONFIG_FILE="$PROJECT_DIR/dashboard-conf.yaml"

APISIX_IMAGE="apache/apisix:3.18.0-debian"
ETCD_IMAGE="quay.io/coreos/etcd:v3.5.18"
DASHBOARD_IMAGE="apache/apisix-dashboard:3.0.1-alpine"

readonly DEFAULT_APISIX_HTTP_PORT=9080
readonly DEFAULT_APISIX_HTTPS_PORT=9443
readonly DEFAULT_APISIX_ADMIN_PORT=9180
readonly DEFAULT_APISIX_ADMIN_BIND='127.0.0.1'
readonly DEFAULT_DASHBOARD_PORT=9000
readonly DEFAULT_NACOS_NAMESPACE_ID='public'
readonly DEFAULT_NACOS_GROUP_NAME='DEFAULT_GROUP'
readonly DEFAULT_NACOS_SERVICE_NAME='outlook-email'
readonly DEFAULT_DASHBOARD_USERNAME='admin'
readonly DASHBOARD_PASSWORD_MIN_LENGTH=8

NACOS_SERVER_URL="${NACOS_SERVER_URL:-}"
NACOS_SERVICE_NAME="${NACOS_SERVICE_NAME:-}"
NACOS_NAMESPACE_ID="${NACOS_NAMESPACE_ID:-$DEFAULT_NACOS_NAMESPACE_ID}"
NACOS_GROUP_NAME="${NACOS_GROUP_NAME:-$DEFAULT_NACOS_GROUP_NAME}"
NACOS_USERNAME="${NACOS_USERNAME:-}"
NACOS_PASSWORD="${NACOS_PASSWORD:-}"
APISIX_HTTP_PORT="${APISIX_HTTP_PORT:-$DEFAULT_APISIX_HTTP_PORT}"
APISIX_HTTPS_PORT="${APISIX_HTTPS_PORT:-$DEFAULT_APISIX_HTTPS_PORT}"
APISIX_ADMIN_PORT="${APISIX_ADMIN_PORT:-$DEFAULT_APISIX_ADMIN_PORT}"
APISIX_ADMIN_BIND="${APISIX_ADMIN_BIND:-$DEFAULT_APISIX_ADMIN_BIND}"
APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-}"
ENABLE_DASHBOARD="${ENABLE_DASHBOARD:-}"
DASHBOARD_PORT="${DASHBOARD_PORT:-$DEFAULT_DASHBOARD_PORT}"
DASHBOARD_USERNAME="${DASHBOARD_USERNAME:-}"
DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD:-}"
DASHBOARD_JWT_SECRET="${DASHBOARD_JWT_SECRET:-}"

log() { printf '[install-apisix-nacos] %s\n' "$*"; }
warn() { printf '[install-apisix-nacos] WARNING: %s\n' "$*" >&2; }
die() { printf '[install-apisix-nacos] ERROR: %s\n' "$*" >&2; exit 1; }

effective_uid() {
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
    ETCD_DATA_DIR="$DATA_DIR/etcd"
    COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
    ENV_FILE="$PROJECT_DIR/.env"
    APISIX_CONFIG_FILE="$PROJECT_DIR/config.yaml"
    DASHBOARD_CONFIG_FILE="$PROJECT_DIR/dashboard-conf.yaml"
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

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
        return 0
    fi
    if [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
        return 0
    fi
    die 'No secure random source is available.'
}

yaml_single_quote() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

normalize_url() {
    local value="$1"
    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done
    printf '%s\n' "$value"
}

url_origin() {
    local value="$1" scheme rest authority
    scheme="${value%%://*}"
    rest="${value#*://}"
    authority="${rest%%/*}"
    printf '%s://%s\n' "$scheme" "$authority"
}

validate_url() {
    local value="$1"
    [[ "$value" =~ ^https?://[^/:[:space:]?#]+(:[0-9]+)?(/nacos)?/?$ ]] \
        || die 'URL must use http or https://host[:port] with an optional /nacos path and no query or fragment.'
}

validate_identifier() {
    local label="$1" value="$2"
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
        || die "$label must use letters, digits, dot, dash, or underscore."
}

validate_port() {
    local label="$1" value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] \
        || die "$label port must be an integer."
    ((10#$value >= 1024 && 10#$value <= 65535)) \
        || die "$label port must be between 1024 and 65535."
}

validate_admin_bind() {
    [[ "$1" == '127.0.0.1' ]] \
        || die 'Admin API bind must be 127.0.0.1.'
}

validate_nacos_credentials() {
    if [[ -z "$NACOS_USERNAME" && -z "$NACOS_PASSWORD" ]]; then
        return 0
    fi
    [[ -n "$NACOS_USERNAME" && -n "$NACOS_PASSWORD" ]] \
        || die 'NACOS_USERNAME and NACOS_PASSWORD must be provided together.'
    [[ "$NACOS_USERNAME" != *$'\n'* && "$NACOS_USERNAME" != *$'\r'* ]] \
        || die 'NACOS_USERNAME cannot contain newlines.'
    [[ "$NACOS_PASSWORD" != *$'\n'* && "$NACOS_PASSWORD" != *$'\r'* ]] \
        || die 'NACOS_PASSWORD cannot contain newlines.'
    [[ "$NACOS_USERNAME" != *[[:space:]:@/?#]* ]] \
        || die 'NACOS_USERNAME contains unsupported characters.'
    [[ "$NACOS_PASSWORD" != *[[:space:]:@/?#]* ]] \
        || die 'NACOS_PASSWORD contains unsupported characters.'
}

validate_dashboard_credentials() {
    if [[ -z "$DASHBOARD_USERNAME" && -z "$DASHBOARD_PASSWORD" ]]; then
        return 0
    fi
    validate_identifier 'dashboard username' "$DASHBOARD_USERNAME"
    [[ -n "$DASHBOARD_PASSWORD" ]] \
        || die 'Dashboard password cannot be empty.'
    [[ "$DASHBOARD_PASSWORD" != *$'\n'* && "$DASHBOARD_PASSWORD" != *$'\r'* ]] \
        || die 'Dashboard password cannot contain newlines.'
    (( ${#DASHBOARD_PASSWORD} >= DASHBOARD_PASSWORD_MIN_LENGTH )) \
        || die "Dashboard password must be at least $DASHBOARD_PASSWORD_MIN_LENGTH characters."
}

require_linux() {
    [[ "$(uname -s)" == 'Linux' ]] || die 'This installer supports Linux servers only.'
}

require_privileges() {
    if [[ "$(effective_uid)" -eq 0 ]]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || die 'Run as root or install sudo before running this installer.'
    sudo -v || die 'Unable to obtain sudo privileges.'
}

ensure_docker() {
    command -v curl >/dev/null 2>&1 || die 'curl is required.'
    command -v docker >/dev/null 2>&1 || die 'Docker is not installed.'
    docker_cmd info >/dev/null 2>&1 || die 'Docker daemon is not available.'
}

ensure_compose() {
    docker_cmd compose version >/dev/null 2>&1 || die 'Docker Compose v2 plugin is not available.'
}

validate_compose() {
    compose_cmd config -q
}

wait_for_ready() {
    local deadline=$((SECONDS + 300))
    while ((SECONDS < deadline)); do
        if curl -sS --connect-timeout 5 --max-time 5 --output /dev/null "http://127.0.0.1:${APISIX_HTTP_PORT}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

redact_sensitive_text() {
    local text="$1" secret
    for secret in "$NACOS_USERNAME" "$NACOS_PASSWORD" "$APISIX_ADMIN_KEY" "$DASHBOARD_USERNAME" "$DASHBOARD_PASSWORD" "$DASHBOARD_JWT_SECRET"; do
        [[ -n "$secret" ]] || continue
        text="${text//"$secret"/[REDACTED]}"
    done
    printf '%s' "$text"
}

show_failure_diagnostics() {
    local output
    output="$(compose_cmd ps 2>&1 || true)"
    [[ -n "$output" ]] && redact_sensitive_text "$output" >&2
    printf '\n' >&2
    output="$(compose_cmd logs --tail 100 etcd apisix 2>&1 || true)"
    [[ -n "$output" ]] && redact_sensitive_text "$output" >&2
    if [[ "$ENABLE_DASHBOARD" == '1' ]]; then
        printf '\n' >&2
        output="$(compose_cmd logs --tail 100 apisix-dashboard 2>&1 || true)"
        [[ -n "$output" ]] && redact_sensitive_text "$output" >&2
    fi
    printf '\n' >&2
}

show_service_status() {
    compose_cmd ps
}

refresh_and_start() {
    validate_compose
    compose_cmd up -d --remove-orphans
}

required_value() {
    local variable_name="$1"
    local prompt="$2"
    local validator="$3"
    shift 3
    local current="${!variable_name-}"
    local entered value
    if [[ -n "$current" ]]; then
        "$validator" "$@" "$current"
        return 0
    fi
    while true; do
        printf '%s: ' "$prompt" >&2
        if ! IFS= read -r entered; then
            printf '\n' >&2
            die "$prompt is required."
        fi
        value="$entered"
        [[ -n "$value" ]] || {
            warn "$prompt cannot be empty."
            continue
        }
        if ( "$validator" "$@" "$value" ) >/dev/null 2>&1; then
            printf -v "$variable_name" '%s' "$value"
            return 0
        fi
        warn "$prompt is invalid."
    done
}

prompt_secret() {
    local prompt="$1"
    local value=''
    printf '%s: ' "$prompt" >&2
    if ! IFS= read -r -s value; then
        printf '\n' >&2
        die "$prompt is required."
    fi
    printf '\n' >&2
    [[ -n "$value" ]] || die "$prompt cannot be empty."
    printf '%s\n' "$value"
}

resolve_nacos_credentials() {
    local env_username env_password
    if [[ -n "$NACOS_USERNAME" || -n "$NACOS_PASSWORD" ]]; then
        validate_nacos_credentials
        return 0
    fi
    env_username="$(read_env_value "$ENV_FILE" NACOS_USERNAME || true)"
    env_password="$(read_env_value "$ENV_FILE" NACOS_PASSWORD || true)"
    if [[ -n "$env_username" || -n "$env_password" ]]; then
        NACOS_USERNAME="$env_username"
        NACOS_PASSWORD="$env_password"
        validate_nacos_credentials
        return 0
    fi
    printf 'Nacos username (blank for no authentication): ' >&2
    if ! IFS= read -r NACOS_USERNAME; then
        printf '\n' >&2
        die 'Nacos username is required.'
    fi
    if [[ -z "$NACOS_USERNAME" ]]; then
        NACOS_PASSWORD=''
        return 0
    fi
    if ! ( validate_identifier 'nacos username' "$NACOS_USERNAME" ) >/dev/null 2>&1; then
        die 'Nacos username is invalid.'
    fi
    NACOS_PASSWORD="$(prompt_secret 'Nacos password')"
    validate_nacos_credentials
}

resolve_dashboard_credentials() {
    [[ "$ENABLE_DASHBOARD" == '1' ]] || return 0
    if [[ -z "$DASHBOARD_USERNAME" ]]; then
        DASHBOARD_USERNAME="$(read_env_value "$ENV_FILE" DASHBOARD_USERNAME || true)"
    fi
    if [[ -z "$DASHBOARD_PASSWORD" ]]; then
        DASHBOARD_PASSWORD="$(read_env_value "$ENV_FILE" DASHBOARD_PASSWORD || true)"
    fi
    if [[ -z "$DASHBOARD_USERNAME" ]]; then
        DASHBOARD_USERNAME="$DEFAULT_DASHBOARD_USERNAME"
    fi
    validate_identifier 'dashboard username' "$DASHBOARD_USERNAME"
    if [[ -z "$DASHBOARD_PASSWORD" ]]; then
        DASHBOARD_PASSWORD="$(prompt_secret 'Dashboard password')"
    fi
    validate_dashboard_credentials
}

resolve_inputs() {
    if [[ -z "$NACOS_SERVER_URL" ]]; then
        NACOS_SERVER_URL="$(read_env_value "$ENV_FILE" NACOS_SERVER_URL || true)"
    fi
    if [[ -z "$NACOS_SERVER_URL" ]]; then
        required_value NACOS_SERVER_URL 'Nacos server URL' validate_url
    fi
    if [[ -z "$NACOS_SERVICE_NAME" ]]; then
        NACOS_SERVICE_NAME="$(read_env_value "$ENV_FILE" NACOS_SERVICE_NAME || true)"
    fi
    if [[ -z "$NACOS_SERVICE_NAME" ]]; then
        required_value NACOS_SERVICE_NAME 'Nacos service name' validate_identifier service
    fi
    if [[ -z "$NACOS_NAMESPACE_ID" ]]; then
        NACOS_NAMESPACE_ID="$(read_env_value "$ENV_FILE" NACOS_NAMESPACE_ID || true)"
    fi
    if [[ -z "$NACOS_NAMESPACE_ID" ]]; then
        NACOS_NAMESPACE_ID="$DEFAULT_NACOS_NAMESPACE_ID"
    fi
    if [[ -z "$NACOS_GROUP_NAME" ]]; then
        NACOS_GROUP_NAME="$(read_env_value "$ENV_FILE" NACOS_GROUP_NAME || true)"
    fi
    if [[ -z "$NACOS_GROUP_NAME" ]]; then
        NACOS_GROUP_NAME="$DEFAULT_NACOS_GROUP_NAME"
    fi
    if [[ -z "$APISIX_HTTP_PORT" ]]; then
        APISIX_HTTP_PORT="$(read_env_value "$ENV_FILE" APISIX_HTTP_PORT || true)"
    fi
    if [[ -z "$APISIX_HTTP_PORT" ]]; then
        APISIX_HTTP_PORT="$DEFAULT_APISIX_HTTP_PORT"
    fi
    if [[ -z "$APISIX_HTTPS_PORT" ]]; then
        APISIX_HTTPS_PORT="$(read_env_value "$ENV_FILE" APISIX_HTTPS_PORT || true)"
    fi
    if [[ -z "$APISIX_HTTPS_PORT" ]]; then
        APISIX_HTTPS_PORT="$DEFAULT_APISIX_HTTPS_PORT"
    fi
    if [[ -z "$APISIX_ADMIN_PORT" ]]; then
        APISIX_ADMIN_PORT="$(read_env_value "$ENV_FILE" APISIX_ADMIN_PORT || true)"
    fi
    if [[ -z "$APISIX_ADMIN_PORT" ]]; then
        APISIX_ADMIN_PORT="$DEFAULT_APISIX_ADMIN_PORT"
    fi
    if [[ -z "$APISIX_ADMIN_BIND" ]]; then
        APISIX_ADMIN_BIND="$(read_env_value "$ENV_FILE" APISIX_ADMIN_BIND || true)"
    fi
    if [[ -z "$APISIX_ADMIN_BIND" ]]; then
        APISIX_ADMIN_BIND="$DEFAULT_APISIX_ADMIN_BIND"
    fi
    if [[ -z "$DASHBOARD_PORT" ]]; then
        DASHBOARD_PORT="$(read_env_value "$ENV_FILE" DASHBOARD_PORT || true)"
    fi
    if [[ -z "$DASHBOARD_PORT" ]]; then
        DASHBOARD_PORT="$DEFAULT_DASHBOARD_PORT"
    fi
    if [[ -z "$ENABLE_DASHBOARD" ]]; then
        ENABLE_DASHBOARD="$(read_env_value "$ENV_FILE" ENABLE_DASHBOARD || true)"
    fi
    if [[ -z "$ENABLE_DASHBOARD" ]]; then
        local choice=''
        printf 'Enable APISIX Dashboard? [y/N]: ' >&2
        if ! IFS= read -r choice; then
            choice=''
        fi
        case "${choice,,}" in
            y|yes)
                ENABLE_DASHBOARD='1'
                ;;
            *)
                ENABLE_DASHBOARD='0'
                ;;
        esac
    fi
    if [[ -z "$APISIX_ADMIN_KEY" ]]; then
        APISIX_ADMIN_KEY="$(read_env_value "$ENV_FILE" APISIX_ADMIN_KEY || true)"
    fi
    if [[ -z "$APISIX_ADMIN_KEY" ]]; then
        APISIX_ADMIN_KEY="$(generate_secret)"
    fi
}

prepare_env() {
    local nacos_url dashboard_secret env_value
    if [[ -z "$NACOS_SERVER_URL" ]]; then
        env_value="$(read_env_value "$ENV_FILE" NACOS_SERVER_URL || true)"
        [[ -n "$env_value" ]] && NACOS_SERVER_URL="$env_value"
    fi
    if [[ -z "$NACOS_SERVICE_NAME" ]]; then
        env_value="$(read_env_value "$ENV_FILE" NACOS_SERVICE_NAME || true)"
        [[ -n "$env_value" ]] && NACOS_SERVICE_NAME="$env_value"
    fi
    if [[ -z "$NACOS_NAMESPACE_ID" ]]; then
        env_value="$(read_env_value "$ENV_FILE" NACOS_NAMESPACE_ID || true)"
        [[ -n "$env_value" ]] && NACOS_NAMESPACE_ID="$env_value"
    fi
    if [[ -z "$NACOS_GROUP_NAME" ]]; then
        env_value="$(read_env_value "$ENV_FILE" NACOS_GROUP_NAME || true)"
        [[ -n "$env_value" ]] && NACOS_GROUP_NAME="$env_value"
    fi
    if [[ -z "$NACOS_USERNAME" ]]; then
        NACOS_USERNAME="$(read_env_value "$ENV_FILE" NACOS_USERNAME || true)"
    fi
    if [[ -z "$NACOS_PASSWORD" ]]; then
        NACOS_PASSWORD="$(read_env_value "$ENV_FILE" NACOS_PASSWORD || true)"
    fi
    if [[ -z "$APISIX_HTTP_PORT" ]]; then
        env_value="$(read_env_value "$ENV_FILE" APISIX_HTTP_PORT || true)"
        [[ -n "$env_value" ]] && APISIX_HTTP_PORT="$env_value"
    fi
    if [[ -z "$APISIX_HTTPS_PORT" ]]; then
        env_value="$(read_env_value "$ENV_FILE" APISIX_HTTPS_PORT || true)"
        [[ -n "$env_value" ]] && APISIX_HTTPS_PORT="$env_value"
    fi
    if [[ -z "$APISIX_ADMIN_PORT" ]]; then
        env_value="$(read_env_value "$ENV_FILE" APISIX_ADMIN_PORT || true)"
        [[ -n "$env_value" ]] && APISIX_ADMIN_PORT="$env_value"
    fi
    if [[ -z "$APISIX_ADMIN_BIND" ]]; then
        env_value="$(read_env_value "$ENV_FILE" APISIX_ADMIN_BIND || true)"
        [[ -n "$env_value" ]] && APISIX_ADMIN_BIND="$env_value"
    fi
    if [[ -z "$APISIX_ADMIN_KEY" ]]; then
        APISIX_ADMIN_KEY="$(read_env_value "$ENV_FILE" APISIX_ADMIN_KEY || true)"
    fi
    if [[ -z "$ENABLE_DASHBOARD" ]]; then
        ENABLE_DASHBOARD="$(read_env_value "$ENV_FILE" ENABLE_DASHBOARD || true)"
    fi
    if [[ -z "$DASHBOARD_PORT" ]]; then
        env_value="$(read_env_value "$ENV_FILE" DASHBOARD_PORT || true)"
        [[ -n "$env_value" ]] && DASHBOARD_PORT="$env_value"
    fi
    if [[ -z "$DASHBOARD_USERNAME" ]]; then
        DASHBOARD_USERNAME="$(read_env_value "$ENV_FILE" DASHBOARD_USERNAME || true)"
    fi
    if [[ -z "$DASHBOARD_PASSWORD" ]]; then
        DASHBOARD_PASSWORD="$(read_env_value "$ENV_FILE" DASHBOARD_PASSWORD || true)"
    fi
    if [[ -z "$DASHBOARD_JWT_SECRET" ]]; then
        DASHBOARD_JWT_SECRET="$(read_env_value "$ENV_FILE" DASHBOARD_JWT_SECRET || true)"
    fi

    validate_url "$NACOS_SERVER_URL"
    validate_identifier service "$NACOS_SERVICE_NAME"
    validate_identifier namespace "$NACOS_NAMESPACE_ID"
    validate_identifier group "$NACOS_GROUP_NAME"
    validate_port http "$APISIX_HTTP_PORT"
    validate_port https "$APISIX_HTTPS_PORT"
    validate_port admin "$APISIX_ADMIN_PORT"
    validate_admin_bind "$APISIX_ADMIN_BIND"
    validate_nacos_credentials
    if [[ "$ENABLE_DASHBOARD" == '1' ]]; then
        validate_dashboard_credentials
    fi

    nacos_url="$(normalize_url "$NACOS_SERVER_URL")"
    if [[ -z "$APISIX_ADMIN_KEY" ]]; then
        APISIX_ADMIN_KEY="$(generate_secret)"
    fi
    if [[ "$ENABLE_DASHBOARD" == '1' ]]; then
        dashboard_secret="${DASHBOARD_JWT_SECRET:-}"
        if [[ -z "$dashboard_secret" ]]; then
            dashboard_secret="$(read_env_value "$ENV_FILE" DASHBOARD_JWT_SECRET || true)"
        fi
        [[ -n "$dashboard_secret" ]] || dashboard_secret="$(generate_secret)"
        DASHBOARD_JWT_SECRET="$dashboard_secret"
    fi

    mkdir -p "$PROJECT_DIR"
    upsert_env_var "$ENV_FILE" NACOS_SERVER_URL "$nacos_url"
    upsert_env_var "$ENV_FILE" NACOS_SERVICE_NAME "$NACOS_SERVICE_NAME"
    upsert_env_var "$ENV_FILE" NACOS_NAMESPACE_ID "$NACOS_NAMESPACE_ID"
    upsert_env_var "$ENV_FILE" NACOS_GROUP_NAME "$NACOS_GROUP_NAME"
    upsert_env_var "$ENV_FILE" NACOS_USERNAME "$NACOS_USERNAME"
    upsert_env_var "$ENV_FILE" NACOS_PASSWORD "$NACOS_PASSWORD"
    upsert_env_var "$ENV_FILE" APISIX_HTTP_PORT "$APISIX_HTTP_PORT"
    upsert_env_var "$ENV_FILE" APISIX_HTTPS_PORT "$APISIX_HTTPS_PORT"
    upsert_env_var "$ENV_FILE" APISIX_ADMIN_PORT "$APISIX_ADMIN_PORT"
    upsert_env_var "$ENV_FILE" APISIX_ADMIN_BIND "$APISIX_ADMIN_BIND"
    upsert_env_var "$ENV_FILE" APISIX_ADMIN_KEY "$APISIX_ADMIN_KEY"
    upsert_env_var "$ENV_FILE" ENABLE_DASHBOARD "$ENABLE_DASHBOARD"
    upsert_env_var "$ENV_FILE" DASHBOARD_PORT "$DASHBOARD_PORT"
    upsert_env_var "$ENV_FILE" DASHBOARD_USERNAME "$DASHBOARD_USERNAME"
    upsert_env_var "$ENV_FILE" DASHBOARD_PASSWORD "$DASHBOARD_PASSWORD"
    if [[ "$ENABLE_DASHBOARD" == '1' ]]; then
        upsert_env_var "$ENV_FILE" DASHBOARD_JWT_SECRET "$DASHBOARD_JWT_SECRET"
    fi
}

render_nacos_host() {
    local base authority
    base="$(url_origin "$NACOS_SERVER_URL")"
    authority="${base#*://}"
    if [[ -n "$NACOS_USERNAME" ]]; then
        printf '%s://%s:%s@%s\n' \
            "${base%%://*}" \
            "$NACOS_USERNAME" \
            "$NACOS_PASSWORD" \
            "$authority"
    else
        printf '%s\n' "$base"
    fi
}

write_apisix_config() {
    local temporary
    mkdir -p "$PROJECT_DIR"
    temporary="$(mktemp "$PROJECT_DIR/.config.yaml.tmp.XXXXXX")"
    cat >"$temporary" <<EOF
apisix:
  node_listen:
    - $APISIX_HTTP_PORT
  ssl:
    enable: true
    listen:
      - port: $APISIX_HTTPS_PORT
deployment:
  role: traditional
  role_traditional:
    config_provider: etcd
  admin:
    allow_admin:
      - 127.0.0.1/32
      - 172.16.0.0/12
    admin_listen:
      ip: 0.0.0.0
      port: $APISIX_ADMIN_PORT
    admin_key:
      - name: admin
        key: $(yaml_single_quote "$APISIX_ADMIN_KEY")
        role: admin
  etcd:
    host:
      - "http://etcd:2379"
    prefix: "/apisix"
discovery:
  nacos:
    host:
      - $(yaml_single_quote "$(render_nacos_host)")
    prefix: "/nacos/v1/"
    fetch_interval: 30
EOF
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$APISIX_CONFIG_FILE"
    chmod 600 "$APISIX_CONFIG_FILE"
}

write_dashboard_config() {
    local temporary
    if [[ "$ENABLE_DASHBOARD" != '1' ]]; then
        rm -f -- "$DASHBOARD_CONFIG_FILE"
        return 0
    fi
    mkdir -p "$PROJECT_DIR"
    temporary="$(mktemp "$PROJECT_DIR/.dashboard-conf.yaml.tmp.XXXXXX")"
    cat >"$temporary" <<EOF
conf:
  listen:
    host: 0.0.0.0
    port: $DASHBOARD_PORT
  etcd:
    endpoints:
      - etcd:2379
authentication:
  secret: $(yaml_single_quote "$DASHBOARD_JWT_SECRET")
  expire_time: 3600
  users:
    - username: $(yaml_single_quote "$DASHBOARD_USERNAME")
      password: $(yaml_single_quote "$DASHBOARD_PASSWORD")
EOF
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$DASHBOARD_CONFIG_FILE"
    chmod 600 "$DASHBOARD_CONFIG_FILE"
}

write_compose_file() {
    local temporary dashboard_block=''
    mkdir -p "$DATA_DIR"
    temporary="$(mktemp "$PROJECT_DIR/.docker-compose.yml.tmp.XXXXXX")"
    if [[ "$ENABLE_DASHBOARD" == '1' ]]; then
        dashboard_block=$(cat <<EOF

  apisix-dashboard:
    image: $DASHBOARD_IMAGE
    depends_on:
      - etcd
    volumes:
      - ./dashboard-conf.yaml:/usr/local/apisix-dashboard/conf/conf.yaml:ro
    ports:
      - "127.0.0.1:${DASHBOARD_PORT}:9000"
    restart: unless-stopped
EOF
)
    fi
    cat >"$temporary" <<EOF
services:
  etcd:
    image: $ETCD_IMAGE
    command:
      - /usr/local/bin/etcd
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://etcd:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://etcd:2380
      - --initial-cluster=default=http://etcd:2380
      - --initial-cluster-token=apisix-etcd
      - --initial-cluster-state=new
    volumes:
      - ./data/etcd:/etcd-data
    restart: unless-stopped

  apisix:
    image: $APISIX_IMAGE
    depends_on:
      - etcd
    volumes:
      - ./config.yaml:/usr/local/apisix/conf/config.yaml:ro
    ports:
      - "${APISIX_HTTP_PORT}:9080"
      - "${APISIX_HTTPS_PORT}:9443"
      - "127.0.0.1:${APISIX_ADMIN_PORT}:9180"
    restart: unless-stopped$dashboard_block
EOF
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$COMPOSE_FILE"
    chmod 600 "$COMPOSE_FILE"
}

usage() {
    cat <<'USAGE'
Usage: install-apisix-nacos.sh [options]

Options:
  --project-dir PATH
  --nacos-url URL
  --nacos-service NAME
  --nacos-namespace ID
  --nacos-group NAME
  --nacos-username USER
  --http-port PORT
  --https-port PORT
  --admin-port PORT
  --admin-bind IP
  --admin-key KEY
  --dashboard
  --dashboard-port PORT
  --dashboard-username USER
  --dashboard-password PASS
  -h, --help
USAGE
}

main() {
    local project_dir_arg=''
    while (($# > 0)); do
        case "$1" in
            --project-dir)
                [[ $# -ge 2 ]] || die '--project-dir requires a value.'
                project_dir_arg="$2"
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
            --nacos-username)
                [[ $# -ge 2 ]] || die '--nacos-username requires a value.'
                NACOS_USERNAME="$2"
                shift 2
                ;;
            --http-port)
                [[ $# -ge 2 ]] || die '--http-port requires a value.'
                APISIX_HTTP_PORT="$2"
                shift 2
                ;;
            --https-port)
                [[ $# -ge 2 ]] || die '--https-port requires a value.'
                APISIX_HTTPS_PORT="$2"
                shift 2
                ;;
            --admin-port)
                [[ $# -ge 2 ]] || die '--admin-port requires a value.'
                APISIX_ADMIN_PORT="$2"
                shift 2
                ;;
            --admin-bind)
                [[ $# -ge 2 ]] || die '--admin-bind requires a value.'
                APISIX_ADMIN_BIND="$2"
                shift 2
                ;;
            --admin-key)
                [[ $# -ge 2 ]] || die '--admin-key requires a value.'
                APISIX_ADMIN_KEY="$2"
                shift 2
                ;;
            --dashboard)
                ENABLE_DASHBOARD='1'
                shift
                ;;
            --dashboard-port)
                [[ $# -ge 2 ]] || die '--dashboard-port requires a value.'
                DASHBOARD_PORT="$2"
                ENABLE_DASHBOARD='1'
                shift 2
                ;;
            --dashboard-username)
                [[ $# -ge 2 ]] || die '--dashboard-username requires a value.'
                DASHBOARD_USERNAME="$2"
                ENABLE_DASHBOARD='1'
                shift 2
                ;;
            --dashboard-password)
                [[ $# -ge 2 ]] || die '--dashboard-password requires a value.'
                DASHBOARD_PASSWORD="$2"
                ENABLE_DASHBOARD='1'
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
    resolve_inputs
    resolve_nacos_credentials
    resolve_dashboard_credentials
    require_linux
    require_privileges
    ensure_docker
    ensure_compose
    prepare_env
    write_apisix_config
    write_dashboard_config
    write_compose_file

    if ! refresh_and_start; then
        show_failure_diagnostics
        die 'APISIX deployment failed to start.'
    fi
    if ! wait_for_ready; then
        show_failure_diagnostics
        die 'APISIX did not become ready in time.'
    fi

    show_service_status
    log "Rendered APISIX config: $APISIX_CONFIG_FILE"
    log "Rendered Compose file: $COMPOSE_FILE"
    if [[ "$ENABLE_DASHBOARD" == '1' ]]; then
        log "Rendered Dashboard config: $DASHBOARD_CONFIG_FILE"
    fi
    log "APISIX is ready at http://127.0.0.1:${APISIX_HTTP_PORT}"
}

if [[ "${INSTALLER_LIB_ONLY:-0}" != '1' ]]; then
    main "$@"
fi
