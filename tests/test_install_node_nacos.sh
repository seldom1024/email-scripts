#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT_DIR/install-node-nacos.sh"

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

[[ -f "$SCRIPT" ]] || fail "$SCRIPT does not exist"

export INSTALLER_LIB_ONLY=1
# shellcheck disable=SC1090
. "$SCRIPT"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

set_project_dir "$tmp_dir"
NACOS_SERVER_URL='https://nacos.example.test:8848/nacos/'
NACOS_SERVICE_NAME='outlook-email'
NACOS_ADVERTISE_IP='198.51.100.24'
NACOS_NAMESPACE_ID='public'
NACOS_GROUP_NAME='DEFAULT_GROUP'
NACOS_CLUSTER_NAME='DEFAULT'

write_compose_file
write_registrar_file

assert_contains "$COMPOSE_FILE" 'nacos-registrar:'
assert_contains "$COMPOSE_FILE" 'image: python:3.12-alpine'
assert_contains "$COMPOSE_FILE" 'NACOS_ADVERTISE_IP=${NACOS_ADVERTISE_IP}'
assert_contains "$COMPOSE_FILE" 'REPLICA_READY_URL=http://outlook-mail-replica:5000/health/ready'
assert_contains "$COMPOSE_FILE" './nacos/registrar.py:/app/registrar.py:ro'
assert_contains "$REGISTRAR_FILE" 'class NacosRegistrar'
assert_contains "$REGISTRAR_FILE" '/nacos/v3/auth/user/login'
assert_contains "$REGISTRAR_FILE" '/nacos/v3/client/ns/instance'
assert_contains "$REGISTRAR_FILE" 'Authorization'
assert_not_contains "$REGISTRAR_FILE" '/nacos/v1/'
assert_not_contains "$REGISTRAR_FILE" '"accessToken"] ='
assert_equals "$(stat -c '%a' "$REGISTRAR_FILE")" '600'

assert_not_contains "$SCRIPT" 'api.ipify.org'
assert_not_contains "$SCRIPT" 'ifconfig.me'
assert_not_contains "$SCRIPT" '--nacos-password'

validate_nacos_url 'http://127.0.0.1:8848'
validate_ipv4 '198.51.100.24'
validate_nacos_identifier service 'outlook-email:v1'
NACOS_USERNAME='nacos'
NACOS_PASSWORD='secret'
validate_nacos_credentials

expect_failure 'URL with unsupported scheme' validate_nacos_url 'ftp://nacos.example.test'
expect_failure 'URL with query string' validate_nacos_url 'https://nacos.example.test?n=1'
expect_failure 'invalid IPv4 octet' validate_ipv4 '198.51.100.999'
expect_failure 'loopback advertised address' validate_ipv4 '127.0.0.1'
expect_failure 'identifier with whitespace' validate_nacos_identifier service 'bad service'
NACOS_USERNAME='nacos'
NACOS_PASSWORD=''
expect_failure 'partial Nacos credentials' validate_nacos_credentials

NACOS_USERNAME='env-user'
NACOS_PASSWORD='env-password'
OUTLOOK_EMAIL_PORT='5100'
MASTER_URL='https://master.example.test'
prepare_env

assert_contains "$ENV_FILE" 'NACOS_SERVER_URL=https://nacos.example.test:8848/nacos'
assert_contains "$ENV_FILE" 'NACOS_SERVICE_NAME=outlook-email'
assert_contains "$ENV_FILE" 'NACOS_ADVERTISE_IP=198.51.100.24'
assert_contains "$ENV_FILE" 'NACOS_USERNAME=env-user'
assert_contains "$ENV_FILE" 'NACOS_PASSWORD=env-password'
assert_equals "$(stat -c '%a' "$ENV_FILE")" '600'

NACOS_USERNAME=''
NACOS_PASSWORD=''
resolve_nacos_credentials
assert_equals "$NACOS_USERNAME" 'env-user'
assert_equals "$NACOS_PASSWORD" 'env-password'

python_command="$(command -v python3 || command -v python || true)"
[[ -n "$python_command" ]] || fail 'python3 or python is required for registrar tests'
"$python_command" -c \
    'import pathlib, sys; path = pathlib.Path(sys.argv[1]); compile(path.read_text(encoding="utf-8"), str(path), "exec")' \
    "$REGISTRAR_FILE"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config -q
fi
"$python_command" "$ROOT_DIR/tests/test_nacos_registrar.py" "$REGISTRAR_FILE"
printf 'PASS: install-node-nacos contract and lifecycle\n'
