#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(pwd -P)"
DATA_DIR="$PROJECT_DIR/data"
IDENTITY_DIR="$DATA_DIR/cluster"
IDENTITY_DB="$IDENTITY_DIR/identity.db"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
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
        ubuntu|debian|centos|rhel|rocky|almalinux)
            printf '%s\n' "${distro_id,,}"
            ;;
        *)
            die "Unsupported Linux distribution: ${distro_id:-unknown}. Supported: Ubuntu, Debian, CentOS, RHEL, Rocky Linux, AlmaLinux."
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
    upsert_env_var "$ENV_FILE" OUTLOOK_EMAIL_PORT "$configured_port"
    upsert_env_var "$ENV_FILE" MASTER_URL "$MASTER_URL"
    upsert_env_var "$ENV_FILE" SECRET_KEY "$secret_key"
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
    docker_cmd logs --tail 100 "$CONTAINER_NAME" || true
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
    printf 'Identity: %s\n' "$IDENTITY_DB"
    printf 'Environment: %s\n' "$ENV_FILE"
}

usage() {
    cat <<'USAGE'
Usage: install-node.sh --master URL --node-id ID --master-fingerprint FINGERPRINT [--v VERSION] [--n CONTAINER_NAME] [--p PORT] [--install-dir PATH]

Install or repair Docker and Docker Compose, persist replica-local configuration,
enroll the replica when needed, pull the selected seldomzq/email image, and start the node.

The default install directory is the current working directory.
--v VERSION selects the email image tag (default: latest).
--n CONTAINER_NAME selects the replica container name (default: outlook-mail-reader).
--p PORT selects the host port mapped to container port 5000 (default: 5000).
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

    [[ -n "$MASTER_URL" ]] || die '--master is required.'
    [[ -n "$NODE_ID" ]] || die '--node-id is required.'
    [[ -n "$MASTER_FINGERPRINT" ]] || die '--master-fingerprint is required.'
    validate_master_url "$MASTER_URL"
    MASTER_URL="$(normalize_master_url "$MASTER_URL")"
    validate_node_id "$NODE_ID"
    validate_master_fingerprint "$MASTER_FINGERPRINT"

    if [[ -n "$project_dir_arg" ]]; then
        mkdir -p "$project_dir_arg"
        PROJECT_DIR="$(cd -- "$project_dir_arg" && pwd -P)"
        DATA_DIR="$PROJECT_DIR/data"
        IDENTITY_DIR="$DATA_DIR/cluster"
        IDENTITY_DB="$IDENTITY_DIR/identity.db"
        COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
        ENV_FILE="$PROJECT_DIR/.env"
    fi

    require_linux_systemd
    require_privileges
    distro="$(detect_os)"
    ensure_docker "$distro"
    ensure_host_tools "$distro"
    ensure_compose "$distro"

    mkdir -p "$DATA_DIR"
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
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
