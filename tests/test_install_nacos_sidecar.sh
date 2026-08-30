#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT_DIR/install-nacos-sidecar.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_not_contains() { grep -Fq -- "$2" "$1" && fail "$1 unexpectedly contains: $2" || true; }
assert_equals() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_mode_600() { assert_equals "$(stat -c '%a' "$1")" 600; }
expect_failure() { local description="$1"; shift; if ("$@") >/dev/null 2>&1; then fail "$description unexpectedly succeeded"; fi; }

[[ -f "$SCRIPT" ]] || fail "$SCRIPT does not exist"
export INSTALLER_LIB_ONLY=1
# shellcheck disable=SC1090
. "$SCRIPT"

declare -F set_project_dir >/dev/null || fail 'set_project_dir is not implemented'
declare -F prepare_env >/dev/null || fail 'prepare_env is not implemented'
declare -F write_registrar_file >/dev/null || fail 'write_registrar_file is not implemented'
declare -F write_compose_file >/dev/null || fail 'write_compose_file is not implemented'
declare -F validate_nacos_url >/dev/null || fail 'validate_nacos_url is not implemented'
declare -F validate_ipv4 >/dev/null || fail 'validate_ipv4 is not implemented'
declare -F validate_port >/dev/null || fail 'validate_port is not implemented'
declare -F validate_ready_url >/dev/null || fail 'validate_ready_url is not implemented'
declare -F validate_nacos_credentials >/dev/null || fail 'validate_nacos_credentials is not implemented'

assert_equals "$DEFAULT_NACOS_SERVICE_NAME" mail-cluster
assert_equals "$DEFAULT_NACOS_NAMESPACE_ID" public
assert_equals "$DEFAULT_NACOS_GROUP_NAME" DEFAULT_GROUP
assert_equals "$DEFAULT_NACOS_CLUSTER_NAME" DEFAULT
assert_equals "$DEFAULT_ADVERTISE_PORT" 5000
assert_equals "$DEFAULT_READY_URL" http://127.0.0.1:5000/health/ready
assert_equals "$DEFAULT_PROJECT_DIR" ./mail-nacos-sidecar
assert_not_contains "$SCRIPT" api.ipify.org
assert_not_contains "$SCRIPT" ifconfig.me
assert_not_contains "$SCRIPT" --nacos-password

validate_nacos_url http://nacos.example.test:8848/nacos
validate_ipv4 198.51.100.20
validate_port advertise 5000
validate_ready_url http://127.0.0.1:5000/health/ready
NACOS_USERNAME='nacos-user'; NACOS_PASSWORD='safe-password'; validate_nacos_credentials
expect_failure 'unsupported URL scheme' validate_nacos_url ftp://nacos.example.test
expect_failure 'URL query' validate_nacos_url 'http://nacos.example.test?n=1'
expect_failure 'invalid IPv4' validate_ipv4 198.51.100.999
expect_failure 'loopback IPv4' validate_ipv4 127.0.0.1
expect_failure 'privileged port' validate_port advertise 80
expect_failure 'port above range' validate_port advertise 70000
expect_failure 'ready URL query' validate_ready_url 'http://127.0.0.1:5000/health/ready?x=1'
NACOS_USERNAME='nacos-user'; NACOS_PASSWORD=''; expect_failure 'partial credentials' validate_nacos_credentials

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
set_project_dir "$tmp_dir/project"
NACOS_SERVER_URL='http://nacos.example.test:8848/nacos'
NACOS_SERVICE_NAME='mail-cluster'
NACOS_ADVERTISE_IP='198.51.100.20'
NACOS_ADVERTISE_PORT='5000'
NACOS_NAMESPACE_ID='public'
NACOS_GROUP_NAME='DEFAULT_GROUP'
NACOS_CLUSTER_NAME='DEFAULT'
REPLICA_READY_URL='http://127.0.0.1:5000/health/ready'
NACOS_USERNAME='nacos-user'
NACOS_PASSWORD='safe-password'
prepare_env
write_registrar_file
write_compose_file

assert_contains "$COMPOSE_FILE" 'nacos-registrar:'
assert_contains "$COMPOSE_FILE" 'network_mode: host'
assert_contains "$COMPOSE_FILE" 'image: python:3.12-alpine'
assert_contains "$COMPOSE_FILE" './nacos/registrar.py:/app/registrar.py:ro'
assert_contains "$COMPOSE_FILE" 'REPLICA_READY_URL=${REPLICA_READY_URL}'
assert_not_contains "$COMPOSE_FILE" 'outlook-mail-replica'
assert_not_contains "$COMPOSE_FILE" 'outlook-email'
assert_not_contains "$COMPOSE_FILE" 'ports:'
assert_not_contains "$COMPOSE_FILE" 'safe-password'
assert_contains "$REGISTRAR_FILE" '/nacos/v1/auth/users/login'
assert_contains "$REGISTRAR_FILE" '/nacos/v1/ns/instance'
assert_contains "$REGISTRAR_FILE" '/nacos/v1/ns/instance/beat'
assert_mode_600 "$ENV_FILE"
assert_mode_600 "$REGISTRAR_FILE"
assert_mode_600 "$COMPOSE_FILE"

printf 'PASS: standalone Nacos Sidecar contract\n'
