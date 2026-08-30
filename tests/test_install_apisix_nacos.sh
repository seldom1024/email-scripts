#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT_DIR/install-apisix-nacos.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local file="$1" expected="$2"
    grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_not_contains() {
    local file="$1" unexpected="$2"
    if grep -Fq -- "$unexpected" "$file"; then
        fail "$file unexpectedly contains: $unexpected"
    fi
}

assert_equals() {
    local actual="$1" expected="$2"
    [[ "$actual" == "$expected" ]] \
        || fail "expected '$expected', got '$actual'"
}

expect_failure() {
    local description="$1"
    shift
    if ("$@") >/dev/null 2>&1; then
        fail "$description unexpectedly succeeded"
    fi
}

assert_mode_600() {
    local file="$1"
    assert_equals "$(stat -c '%a' "$file")" '600'
}

repeat_char() {
    local count="$1" char="$2" value=''
    while (( ${#value} < count )); do
        value+="$char"
    done
    printf '%s' "$value"
}

[[ -f "$SCRIPT" ]] || fail "$SCRIPT does not exist"

export INSTALLER_LIB_ONLY=1
# shellcheck disable=SC1090
. "$SCRIPT"

declare -F set_project_dir >/dev/null \
    || fail 'set_project_dir is not implemented'
declare -F prepare_env >/dev/null \
    || fail 'prepare_env is not implemented'
declare -F validate_url >/dev/null \
    || fail 'validate_url is not implemented'
declare -F validate_identifier >/dev/null \
    || fail 'validate_identifier is not implemented'
declare -F validate_port >/dev/null \
    || fail 'validate_port is not implemented'
declare -F validate_nacos_credentials >/dev/null \
    || fail 'validate_nacos_credentials is not implemented'
declare -F validate_admin_bind >/dev/null \
    || fail 'validate_admin_bind is not implemented'
declare -F validate_dashboard_credentials >/dev/null \
    || fail 'validate_dashboard_credentials is not implemented'
declare -F write_apisix_config >/dev/null \
    || fail 'write_apisix_config is not implemented'
declare -F write_dashboard_config >/dev/null \
    || fail 'write_dashboard_config is not implemented'
declare -F write_compose_file >/dev/null \
    || fail 'write_compose_file is not implemented'

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

set_project_dir "$tmp_dir/project"
mkdir -p "$PROJECT_DIR"

NACOS_SERVER_URL='http://nacos.example.test:8848/nacos'
NACOS_SERVICE_NAME='outlook-email'
NACOS_NAMESPACE_ID='public'
NACOS_GROUP_NAME='DEFAULT_GROUP'
NACOS_USERNAME=''
NACOS_PASSWORD=''
APISIX_HTTP_PORT='9080'
APISIX_HTTPS_PORT='9443'
APISIX_ADMIN_PORT='9180'
APISIX_ADMIN_BIND='127.0.0.1'
ENABLE_DASHBOARD='0'
DASHBOARD_PORT='9000'
DASHBOARD_USERNAME=''
DASHBOARD_PASSWORD=''
APISIX_ADMIN_KEY='admin.default-key'

validate_url "$NACOS_SERVER_URL"
validate_identifier service "$NACOS_SERVICE_NAME"
validate_identifier namespace "$NACOS_NAMESPACE_ID"
validate_identifier group "$NACOS_GROUP_NAME"
validate_port proxy "$APISIX_HTTP_PORT"
validate_port proxy "$APISIX_HTTPS_PORT"
validate_port admin "$APISIX_ADMIN_PORT"
validate_admin_bind "$APISIX_ADMIN_BIND"
validate_nacos_credentials

assert_equals "$NACOS_SERVER_URL" 'http://nacos.example.test:8848/nacos'
assert_equals "$NACOS_SERVICE_NAME" 'outlook-email'
assert_equals "$NACOS_NAMESPACE_ID" 'public'
assert_equals "$NACOS_GROUP_NAME" 'DEFAULT_GROUP'
assert_equals "$NACOS_USERNAME" ''
assert_equals "$NACOS_PASSWORD" ''
assert_equals "$APISIX_HTTP_PORT" '9080'
assert_equals "$APISIX_HTTPS_PORT" '9443'
assert_equals "$APISIX_ADMIN_PORT" '9180'
assert_equals "$APISIX_ADMIN_BIND" '127.0.0.1'
assert_equals "$DASHBOARD_PORT" '9000'

expect_failure 'unsupported Nacos URL scheme' \
    validate_url 'ftp://nacos.example.test'
expect_failure 'Nacos URL with query string' \
    validate_url 'http://nacos.example.test:8848/nacos?bad=1'
expect_failure 'invalid service name' \
    validate_identifier service 'bad service'
expect_failure 'privileged proxy port' \
    validate_port proxy '80'
expect_failure 'port above range' \
    validate_port admin '70000'
expect_failure 'public Admin API bind' \
    validate_admin_bind '0.0.0.0'

[[ "${DASHBOARD_PASSWORD_MIN_LENGTH:-}" =~ ^[0-9]+$ ]] \
    || fail 'DASHBOARD_PASSWORD_MIN_LENGTH must be numeric'
(( DASHBOARD_PASSWORD_MIN_LENGTH >= 2 )) \
    || fail 'DASHBOARD_PASSWORD_MIN_LENGTH must be at least 2'
DASHBOARD_USERNAME='dashboard-admin'
DASHBOARD_PASSWORD="$(repeat_char "$((DASHBOARD_PASSWORD_MIN_LENGTH - 1))" 'x')"
expect_failure 'dashboard password shorter than minimum' \
    validate_dashboard_credentials

render_log="$tmp_dir/render.log"
: >"$render_log"

prepare_env >>"$render_log" 2>&1
write_apisix_config >>"$render_log" 2>&1
write_dashboard_config >>"$render_log" 2>&1
write_compose_file >>"$render_log" 2>&1

assert_contains "$APISIX_CONFIG_FILE" 'prefix: "/nacos/v1/"'
assert_contains "$APISIX_CONFIG_FILE" 'fetch_interval: 30'
assert_contains "$COMPOSE_FILE" 'etcd:'
assert_contains "$COMPOSE_FILE" 'apisix:'
assert_not_contains "$COMPOSE_FILE" 'apisix-dashboard'
assert_contains "$COMPOSE_FILE" '"9080:9080"'
assert_contains "$COMPOSE_FILE" '"9443:9443"'
assert_contains "$COMPOSE_FILE" '"127.0.0.1:9180:9180"'
assert_contains "$COMPOSE_FILE" './config.yaml:/usr/local/apisix/conf/config.yaml:ro'
[[ ! -e "${DASHBOARD_CONFIG_FILE:-$PROJECT_DIR/dashboard-conf.yaml}" ]] \
    || fail 'dashboard config was generated while Dashboard is disabled'

NACOS_USERNAME='nacos-user'
NACOS_PASSWORD='Nacos.Pa$$-123_~'
APISIX_ADMIN_KEY='Admin.Key-123_~!'
DASHBOARD_USERNAME='dashboard-admin'
DASHBOARD_PASSWORD='Dashboard.Pass-123_~!'
ENABLE_DASHBOARD='1'
DASHBOARD_PORT='9000'

validate_nacos_credentials
validate_dashboard_credentials

prepare_env >>"$render_log" 2>&1
write_apisix_config >>"$render_log" 2>&1
write_dashboard_config >>"$render_log" 2>&1
write_compose_file >>"$render_log" 2>&1

assert_contains "$COMPOSE_FILE" 'apisix-dashboard'
assert_contains "$COMPOSE_FILE" '"127.0.0.1:9000:9000"'
assert_contains "$COMPOSE_FILE" './dashboard-conf.yaml:/usr/local/apisix-dashboard/conf/conf.yaml:ro'

assert_contains "$ENV_FILE" 'NACOS_USERNAME=nacos-user'
assert_contains "$ENV_FILE" 'NACOS_PASSWORD=Nacos.Pa$$-123_~'
assert_contains "$ENV_FILE" 'APISIX_ADMIN_KEY=Admin.Key-123_~!'
assert_contains "$ENV_FILE" 'ENABLE_DASHBOARD=1'
assert_contains "$ENV_FILE" 'DASHBOARD_USERNAME=dashboard-admin'
assert_contains "$ENV_FILE" 'DASHBOARD_PASSWORD=Dashboard.Pass-123_~!'

assert_contains "$APISIX_CONFIG_FILE" 'nacos-user:Nacos.Pa$$-123_~@nacos.example.test:8848'
assert_contains "$APISIX_CONFIG_FILE" 'key: Admin.Key-123_~!'
assert_not_contains "$APISIX_CONFIG_FILE" 'Dashboard.Pass-123_~!'
assert_not_contains "$APISIX_CONFIG_FILE" 'dashboard-admin'

assert_contains "$DASHBOARD_CONFIG_FILE" 'username: dashboard-admin'
assert_contains "$DASHBOARD_CONFIG_FILE" 'password: Dashboard.Pass-123_~!'
assert_not_contains "$DASHBOARD_CONFIG_FILE" 'Admin.Key-123_~!'
assert_not_contains "$DASHBOARD_CONFIG_FILE" 'Nacos.Pa$$-123_~'

assert_not_contains "$COMPOSE_FILE" 'Nacos.Pa$$-123_~'
assert_not_contains "$COMPOSE_FILE" 'Dashboard.Pass-123_~!'
assert_not_contains "$COMPOSE_FILE" 'Admin.Key-123_~!'
assert_not_contains "$render_log" 'Nacos.Pa$$-123_~'
assert_not_contains "$render_log" 'Dashboard.Pass-123_~!'
assert_not_contains "$render_log" 'Admin.Key-123_~!'

assert_mode_600 "$ENV_FILE"
assert_mode_600 "$APISIX_CONFIG_FILE"
assert_mode_600 "$DASHBOARD_CONFIG_FILE"

printf 'PASS: install-apisix-nacos contract\n'
