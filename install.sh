#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
readonly CONTAINER_NAME="outlook-mail-reader"
readonly IMAGE_NAME="seldomzq/email:latest"
readonly DEFAULT_PORT=5000
readonly MIN_PORT=1024
readonly MAX_PORT=65535
readonly HEALTHCHECK_TIMEOUT_SECONDS="${HEALTHCHECK_TIMEOUT_SECONDS:-60}"
readonly HEALTHCHECK_INTERVAL_SECONDS="${HEALTHCHECK_INTERVAL_SECONDS:-2}"

log() { printf '[outlook-email] %s\n' "$*"; }
warn() { printf '[outlook-email] WARNING: %s\n' "$*" >&2; }
die() { printf '[outlook-email] ERROR: %s\n' "$*" >&2; exit 1; }

run_root() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die 'root privileges or sudo are required.'
    fi
}

docker_cmd() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
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
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
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

    log "Installing required host tools: ${missing[*]}"
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
    if ! command -v docker >/dev/null 2>&1; then
        log 'Docker is not installed; installing Docker CE from the official repository.'
        install_docker "$1"
    fi

    if ! docker_cmd info >/dev/null 2>&1; then
        log 'Starting Docker service.'
        run_root systemctl enable --now docker.service
    fi
    docker_cmd info >/dev/null 2>&1 || die 'Docker daemon is not available after startup.'
}

ensure_compose() {
    local distro="$1"
    if ! docker_cmd compose version >/dev/null 2>&1; then
        log 'Docker Compose v2 plugin is not installed; installing it.'
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
    fi
    docker_cmd compose version >/dev/null 2>&1 || die 'Docker Compose v2 plugin is not available after installation.'
    log "$(docker_cmd compose version)"
}

is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( 10#$port >= MIN_PORT && 10#$port <= MAX_PORT ))
}

port_is_used_by_own_container() {
    local port="$1"
    docker_cmd ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Ports}}' 2>/dev/null \
        | grep -Eq "(^|[, ])(0\.0\.0\.0:)?${port}->5000/tcp"
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
        ! docker_cmd ps --format '{{.Ports}}' 2>/dev/null | grep -Eq "(^|[, ])(0\.0\.0\.0:)?${port}->"
    fi
}

choose_port() {
    local configured_port="${1:-$DEFAULT_PORT}"
    local candidate
    if is_port_available "$configured_port"; then
        printf '%s\n' "$configured_port"
        return 0
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
    awk -v prefix="$key=" 'index($0, prefix) == 1 { sub(/^[^=]*=/, ""); print; exit }' "$file"
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
        awk -v prefix="$key=" -v replacement="$key=$value" '
            index($0, prefix) == 1 {
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

generate_login_password() {
    local value=''
    while ((${#value} < 16)); do
        if command -v openssl >/dev/null 2>&1; then
            value+="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"
        elif [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
            value+="$(od -An -N24 -tu1 /dev/urandom | tr -dc '0-9')"
        else
            die 'No secure random source is available for LOGIN_PASSWORD.'
        fi
    done
    printf '%.16s\n' "$value"
}

validate_env_value() {
    local key="$1"
    local value="$2"
    [[ -n "$value" ]] || die "$key cannot be empty after generation."
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$key cannot contain newlines."
    [[ "$value" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]] || die "$key contains characters unsafe for the generated .env file."
}

prepare_env() {
    local configured_port configured_password configured_secret
    local password secret
    configured_port="$(read_env_value "$ENV_FILE" OUTLOOK_EMAIL_PORT || true)"
    configured_password="$(read_env_value "$ENV_FILE" LOGIN_PASSWORD || true)"
    configured_secret="$(read_env_value "$ENV_FILE" SECRET_KEY || true)"

    if [[ -z "$configured_password" ]]; then
        read -r -s -p 'LOGIN_PASSWORD (press Enter to generate): ' password
        printf '\n'
        [[ -n "$password" ]] || password="$(generate_login_password)"
    else
        password="$configured_password"
        log 'Reusing existing LOGIN_PASSWORD from .env.'
    fi

    if [[ -z "$configured_secret" ]]; then
        read -r -s -p 'SECRET_KEY (press Enter to generate): ' secret
        printf '\n'
        [[ -n "$secret" ]] || secret="$(generate_secret_key)"
    else
        secret="$configured_secret"
        log 'Reusing existing SECRET_KEY from .env.'
    fi

    validate_env_value LOGIN_PASSWORD "$password"
    validate_env_value SECRET_KEY "$secret"
    upsert_env_var "$ENV_FILE" OUTLOOK_EMAIL_PORT "$configured_port"
    upsert_env_var "$ENV_FILE" LOGIN_PASSWORD "$password"
    upsert_env_var "$ENV_FILE" SECRET_KEY "$secret"
    chmod 600 "$ENV_FILE"
}

refresh_and_start() {
    log "Pulling the latest $IMAGE_NAME image."
    compose_cmd pull || return $?
    compose_cmd up -d
}

show_failure_diagnostics() {
    warn 'Container health check failed. Recent diagnostics:'
    compose_cmd ps || true
    docker_cmd logs --tail 100 "$CONTAINER_NAME" || true
}

wait_for_health() {
    local port="$1"
    local deadline=$((SECONDS + HEALTHCHECK_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
        if curl -fsS --max-time 5 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$HEALTHCHECK_INTERVAL_SECONDS"
    done
    show_failure_diagnostics
    return 1
}

print_summary() {
    local port="$1"
    local password secret
    password="$(read_env_value "$ENV_FILE" LOGIN_PASSWORD)"
    secret="$(read_env_value "$ENV_FILE" SECRET_KEY)"
    printf '\nOutlookEmail installation completed.\n'
    printf 'URL: http://SERVER_IP:%s\n' "$port"
    printf 'Container: %s\n' "$CONTAINER_NAME"
    printf 'LOGIN_PASSWORD: %s\n' "$password"
    printf 'SECRET_KEY: %s\n' "$secret"
    printf 'Credentials are stored in %s (mode 600).\n' "$ENV_FILE"
}

usage() {
    cat <<'USAGE'
Usage: scripts/install.sh [--project-dir PATH]

Install Docker when needed, configure .env, pull seldomzq/email:latest,
and start the production Compose service.
USAGE
}

main() {
    local project_dir_arg='' distro configured_port selected_port
    while (($# > 0)); do
        case "$1" in
            --project-dir)
                [[ $# -ge 2 ]] || die '--project-dir requires a path.'
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
        PROJECT_DIR="$(cd -- "$project_dir_arg" && pwd)"
        COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
        ENV_FILE="$PROJECT_DIR/.env"
    fi
    [[ -f "$COMPOSE_FILE" ]] || die "Cannot find $COMPOSE_FILE. Run this script from the project or pass --project-dir."

    require_linux_systemd
    require_privileges
    distro="$(detect_os)"
    log "Detected supported distribution: $distro"
    ensure_docker "$distro"
    ensure_host_tools "$distro"
    ensure_compose "$distro"
    command -v curl >/dev/null 2>&1 || die 'curl is required for the health check.'

    mkdir -p "$PROJECT_DIR/data"
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    configured_port="$(read_env_value "$ENV_FILE" OUTLOOK_EMAIL_PORT || true)"
    [[ -n "$configured_port" ]] || configured_port="$DEFAULT_PORT"
    selected_port="$(choose_port "$configured_port")"
    prepare_env
    upsert_env_var "$ENV_FILE" OUTLOOK_EMAIL_PORT "$selected_port"
    if ! refresh_and_start; then
        show_failure_diagnostics
        die 'Docker image pull or Compose startup failed.'
    fi
    wait_for_health "$selected_port" || die 'The container started but did not become healthy.'
    print_summary "$selected_port"
}

if [[ "${INSTALLER_LIB_ONLY:-0}" != '1' ]]; then
    main "$@"
fi
