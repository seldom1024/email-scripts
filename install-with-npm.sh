#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(pwd -P)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
readonly NPM_CONTAINER_NAME="nginx-proxy-manager"
MAIL_CONTAINER_NAME="outlook-mail-reader"
readonly NPM_IMAGE="jc21/nginx-proxy-manager:latest"
MAIL_IMAGE="seldomzq/email:latest"
readonly NPM_PORTS=(80 443 81)
readonly NPM_HEALTHCHECK_TIMEOUT_SECONDS="${NPM_HEALTHCHECK_TIMEOUT_SECONDS:-120}"
readonly MAIL_HEALTHCHECK_TIMEOUT_SECONDS="${MAIL_HEALTHCHECK_TIMEOUT_SECONDS:-60}"
readonly HEALTHCHECK_INTERVAL_SECONDS="${HEALTHCHECK_INTERVAL_SECONDS:-2}"
readonly DEFAULT_DOCKER_COMPOSE_VERSION='v2.40.3'
DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-$DEFAULT_DOCKER_COMPOSE_VERSION}"

log() { printf '[outlook-email-npm] %s\n' "$*"; }
warn() { printf '[outlook-email-npm] WARNING: %s\n' "$*" >&2; }
die() { printf '[outlook-email-npm] ERROR: %s\n' "$*" >&2; exit 1; }

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

validate_container_name() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
        || die 'Container name must start with a letter or digit and use only letters, digits, dot, dash, or underscore.'
}

set_container_name() {
    local name="$1"
    validate_container_name "$name"
    MAIL_CONTAINER_NAME="$name"
}

validate_image_version() {
    local version="$1"
    [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
        || die 'Image version must use letters, digits, dot, dash, or underscore.'
}

set_image_version() {
    local version="$1"
    validate_image_version "$version"
    MAIL_IMAGE="seldomzq/email:$version"
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

machine_architecture() {
    uname -m
}

docker_compose_arch() {
    local architecture
    architecture="$(machine_architecture)"
    case "$architecture" in
        x86_64|amd64) printf '%s\n' x86_64 ;;
        aarch64|arm64) printf '%s\n' aarch64 ;;
        *) die "Unsupported architecture for Docker Compose: $architecture." ;;
    esac
}

install_compose_plugin_binary() (
    local architecture plugin_dir plugin_path temporary url
    [[ "$DOCKER_COMPOSE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die 'DOCKER_COMPOSE_VERSION must use the form vMAJOR.MINOR.PATCH.'
    architecture="$(docker_compose_arch)" || return $?
    plugin_dir='/usr/local/lib/docker/cli-plugins'
    plugin_path="$plugin_dir/docker-compose"
    url="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${architecture}"
    temporary="$(mktemp)"
    trap 'rm -f -- "$temporary"' EXIT
    curl -fL --retry 3 --connect-timeout 10 --output "$temporary" "$url"
    run_root install -d -m 0755 "$plugin_dir"
    run_root install -m 0755 "$temporary" "$plugin_path"
)

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
            amzn)
                local package_manager
                package_manager="$(amazon_linux_package_manager)"
                if run_root "$package_manager" install -y docker-compose-plugin; then
                    if docker_cmd compose version >/dev/null 2>&1; then
                        return 0
                    fi
                    warn 'The native docker-compose-plugin package did not provide Docker Compose; using the official plugin binary.'
                else
                    warn 'docker-compose-plugin is unavailable from the Amazon Linux repository; using the official plugin binary.'
                fi
                install_compose_plugin_binary
                ;;
            *)
                die "Unsupported distribution: $distro"
                ;;
        esac
    fi
    docker_cmd compose version >/dev/null 2>&1 || die 'Docker Compose v2 plugin is not available after installation.'
    log "$(docker_cmd compose version)"
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
    local configured_password configured_secret password secret
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
    upsert_env_var "$ENV_FILE" LOGIN_PASSWORD "$password"
    upsert_env_var "$ENV_FILE" SECRET_KEY "$secret"
    chmod 600 "$ENV_FILE"
}

port_is_used_by_own_npm_container() {
    local port="$1"
    local compose_working_dir
    compose_working_dir="$(
        docker_cmd inspect \
            --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' \
            "$NPM_CONTAINER_NAME" 2>/dev/null
    )" || return 1
    [[ "$compose_working_dir" == "$PROJECT_DIR" ]] || return 1
    docker_cmd ps --filter "name=^${NPM_CONTAINER_NAME}$" --format '{{.Ports}}' 2>/dev/null \
        | grep -Eq "(^|[, ])(0\\.0\\.0\\.0:|\\[::\\]:)?${port}->${port}/tcp"
}

is_tcp_port_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q .
    else
        docker_cmd ps --format '{{.Ports}}' 2>/dev/null \
            | grep -Eq "(^|[, ])(0\\.0\\.0\\.0:|\\[::\\]:)?${port}->"
    fi
}

ensure_npm_ports_available() {
    local port
    local conflicts=()
    for port in "${NPM_PORTS[@]}"; do
        if port_is_used_by_own_npm_container "$port"; then
            continue
        fi
        if is_tcp_port_listening "$port"; then
            conflicts+=("$port")
        fi
    done
    ((${#conflicts[@]} == 0)) \
        || die "Required NPM host ports are already in use: ${conflicts[*]}. Stop the conflicting service and rerun."
}

write_compose_file() {
    mkdir -p "$PROJECT_DIR"
    cat >"$COMPOSE_FILE" <<'COMPOSE'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    networks:
      - npm
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '81:81'
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt

  outlook-mail-reader:
    image: __OUTLOOK_EMAIL_IMAGE__
    container_name: __OUTLOOK_EMAIL_CONTAINER__
    networks:
      - npm
    volumes:
      - ./email/data:/app/data
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - LOGIN_PASSWORD=${LOGIN_PASSWORD}
      - SECRET_KEY=${SECRET_KEY}
      - FLASK_ENV=production
      - DOCKER_UPDATE_ENABLED=true
      - DOCKER_UPDATE_CONTAINER=__OUTLOOK_EMAIL_CONTAINER__
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:5000/ >/dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 20s

networks:
  npm:
    name: npm
    attachable: true
COMPOSE
    sed -i "s|__OUTLOOK_EMAIL_IMAGE__|$MAIL_IMAGE|g" "$COMPOSE_FILE"
    sed -i "s|__OUTLOOK_EMAIL_CONTAINER__|$MAIL_CONTAINER_NAME|g" "$COMPOSE_FILE"
}

show_service_diagnostics() {
    local container="$1"
    warn "Service $container did not start successfully. Recent diagnostics:"
    compose_cmd ps || true
    docker_cmd logs --tail 100 "$container" || true
}

start_npm() {
    log "Pulling $NPM_IMAGE."
    compose_cmd pull npm || return $?
    compose_cmd up -d npm
}

start_mail() {
    log "Pulling $MAIL_IMAGE."
    compose_cmd pull outlook-mail-reader || return $?
    compose_cmd up -d outlook-mail-reader
}

wait_for_npm() {
    local deadline=$((SECONDS + NPM_HEALTHCHECK_TIMEOUT_SECONDS))
    while ((SECONDS < deadline)); do
        if curl -fsS --max-time 5 http://127.0.0.1:81/ >/dev/null 2>&1; then
            return 0
        fi
        sleep "$HEALTHCHECK_INTERVAL_SECONDS"
    done
    return 1
}

wait_for_mail() {
    local deadline=$((SECONDS + MAIL_HEALTHCHECK_TIMEOUT_SECONDS))
    while ((SECONDS < deadline)); do
        if docker_cmd exec "$MAIL_CONTAINER_NAME" \
            curl -fsS --max-time 5 http://127.0.0.1:5000/ >/dev/null 2>&1; then
            return 0
        fi
        sleep "$HEALTHCHECK_INTERVAL_SECONDS"
    done
    return 1
}

deploy_services() {
    local status
    start_npm || {
        status=$?
        show_service_diagnostics "$NPM_CONTAINER_NAME"
        return "$status"
    }
    if ! wait_for_npm; then
        show_service_diagnostics "$NPM_CONTAINER_NAME"
        return 1
    fi
    start_mail || {
        status=$?
        show_service_diagnostics "$MAIL_CONTAINER_NAME"
        return "$status"
    }
    if ! wait_for_mail; then
        show_service_diagnostics "$MAIL_CONTAINER_NAME"
        return 1
    fi
}

print_summary() {
    local password secret
    password="$(read_env_value "$ENV_FILE" LOGIN_PASSWORD)"
    secret="$(read_env_value "$ENV_FILE" SECRET_KEY)"
    printf '\nOutlookEmail with Nginx Proxy Manager installation completed.\n'
    printf 'Nginx Proxy Manager: http://SERVER_IP:81\n'
    printf 'Proxy target scheme: http\n'
    printf 'Proxy target host: %s\n' "$MAIL_CONTAINER_NAME"
    printf 'Proxy target port: 5000\n'
    printf 'LOGIN_PASSWORD: %s\n' "$password"
    printf 'SECRET_KEY: %s\n' "$secret"
    printf 'Compose file: %s\n' "$COMPOSE_FILE"
    printf 'Credentials file: %s (mode 600)\n' "$ENV_FILE"
    printf 'Create a Proxy Host in Nginx Proxy Manager before accessing the mail service publicly.\n'
}

usage() {
    cat <<'USAGE'
Usage: install-with-npm.sh [--v VERSION] [--n CONTAINER_NAME] [--install-dir PATH]

Install Docker when needed, deploy Nginx Proxy Manager on ports 80, 443,
and 81, then deploy OutlookEmail on the private npm Docker network.

The default install directory is the current working directory.
--v VERSION selects the email image tag (default: latest).
--n CONTAINER_NAME selects the mail container name (default: outlook-mail-reader).
--project-dir is retained as an alias for --install-dir.
USAGE
}

main() {
    local project_dir_arg='' distro
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
        mkdir -p "$project_dir_arg"
        PROJECT_DIR="$(cd -- "$project_dir_arg" && pwd -P)"
        COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
        ENV_FILE="$PROJECT_DIR/.env"
    fi

    require_linux_systemd
    require_privileges
    distro="$(detect_os)"
    log "Detected supported distribution: $distro"
    ensure_docker "$distro"
    ensure_host_tools "$distro"
    ensure_compose "$distro"
    command -v curl >/dev/null 2>&1 || die 'curl is required for health checks.'
    ensure_npm_ports_available

    mkdir -p \
        "$PROJECT_DIR/npm/data" \
        "$PROJECT_DIR/npm/letsencrypt" \
        "$PROJECT_DIR/email/data"
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    prepare_env
    write_compose_file

    deploy_services || die 'NPM or OutlookEmail deployment failed.'
    print_summary
}

if [[ "${INSTALLER_LIB_ONLY:-0}" != '1' ]]; then
    main "$@"
fi
