#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT_DIR/install-node-nacos.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equals() {
    local actual="$1" expected="$2"
    [[ "$actual" == "$expected" ]] \
        || fail "expected '$expected', got '$actual'"
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

expect_failure_with_input() {
    local description="$1" expected="$2" input="$3"
    shift 3
    local output
    if output="$(printf '%s' "$input" | "$@" 2>&1)"; then
        fail "$description unexpectedly succeeded"
    fi
    [[ "$output" == *"$expected"* ]] \
        || fail "$description did not report '$expected': $output"
}

[[ -f "$SCRIPT" ]] || fail "$SCRIPT does not exist"

export INSTALLER_LIB_ONLY=1
# shellcheck disable=SC1090
. "$SCRIPT"

declare -F prompt_required_value >/dev/null \
    || fail 'prompt_required_value is not implemented'
declare -F resolve_install_inputs >/dev/null \
    || fail 'resolve_install_inputs is not implemented'

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
set_project_dir "$tmp_dir/project"
mkdir -p "$PROJECT_DIR"
touch "$ENV_FILE"
prompt_output="$tmp_dir/prompts.log"
fingerprint_a="SHA256:$(printf 'a%.0s' {1..64})"
fingerprint_b="SHA256:$(printf 'b%.0s' {1..64})"
fingerprint_c="SHA256:$(printf 'c%.0s' {1..64})"
usage_output="$tmp_dir/usage.txt"

usage >"$usage_output"
assert_contains "$usage_output" 'Omitted required values are requested interactively.'
assert_not_contains "$usage_output" '(required'

reset_inputs() {
    MASTER_URL=''
    NODE_ID=''
    MASTER_FINGERPRINT=''
    NACOS_SERVER_URL=''
    NACOS_SERVICE_NAME=''
    NACOS_ADVERTISE_IP=''
    NACOS_USERNAME=''
    NACOS_PASSWORD=''
    : >"$ENV_FILE"
    : >"$prompt_output"
}

reset_inputs
cat >"$ENV_FILE" <<'ENV'
MASTER_URL=https://env-master.example.test
NACOS_SERVER_URL=https://env-nacos.example.test:8848/nacos
NACOS_SERVICE_NAME=env-service
NACOS_ADVERTISE_IP=198.51.100.99
ENV
MASTER_URL='https://cli-master.example.test/'
NODE_ID='replica-cli'
MASTER_FINGERPRINT="$fingerprint_a"
NACOS_SERVER_URL='https://cli-nacos.example.test:8848/nacos/'
NACOS_SERVICE_NAME='cli-service'
NACOS_ADVERTISE_IP='198.51.100.20'
resolve_install_inputs </dev/null 2>"$prompt_output"
assert_equals "$MASTER_URL" 'https://cli-master.example.test'
assert_equals "$NODE_ID" 'replica-cli'
assert_equals "$NACOS_SERVER_URL" 'https://cli-nacos.example.test:8848/nacos'
assert_equals "$NACOS_SERVICE_NAME" 'cli-service'
assert_equals "$NACOS_ADVERTISE_IP" '198.51.100.20'
[[ ! -s "$prompt_output" ]] || fail 'complete CLI input unexpectedly prompted'

reset_inputs
cat >"$ENV_FILE" <<'ENV'
MASTER_URL=https://env-master.example.test/
NACOS_SERVER_URL=https://env-nacos.example.test:8848/nacos/
NACOS_SERVICE_NAME=env-service
NACOS_ADVERTISE_IP=198.51.100.21
ENV
resolve_install_inputs 2>"$prompt_output" <<INPUT

replica-env
$fingerprint_b



INPUT
assert_equals "$MASTER_URL" 'https://env-master.example.test'
assert_equals "$NODE_ID" 'replica-env'
assert_equals "$MASTER_FINGERPRINT" "$fingerprint_b"
assert_equals "$NACOS_SERVER_URL" 'https://env-nacos.example.test:8848/nacos'
assert_equals "$NACOS_SERVICE_NAME" 'env-service'
assert_equals "$NACOS_ADVERTISE_IP" '198.51.100.21'
assert_contains "$prompt_output" '主节点地址 [https://env-master.example.test/]'
assert_contains "$prompt_output" 'Nacos 服务名 [env-service]'
assert_contains "$prompt_output" '注册 IP [198.51.100.21]'

reset_inputs
resolve_install_inputs 2>"$prompt_output" <<INPUT
https://interactive-master.example.test/
replica-interactive
$fingerprint_c
http://nacos.internal.test:8848/nacos/
outlook-email
203.0.113.25
INPUT
assert_equals "$MASTER_URL" 'https://interactive-master.example.test'
assert_equals "$NODE_ID" 'replica-interactive'
assert_equals "$NACOS_SERVER_URL" 'http://nacos.internal.test:8848/nacos'
assert_equals "$NACOS_SERVICE_NAME" 'outlook-email'
assert_equals "$NACOS_ADVERTISE_IP" '203.0.113.25'

reset_inputs
prompt_required_value NACOS_ADVERTISE_IP '注册 IP' NACOS_ADVERTISE_IP validate_ipv4 \
    2>"$prompt_output" <<'INPUT'
127.0.0.1
198.51.100.22
INPUT
assert_equals "$NACOS_ADVERTISE_IP" '198.51.100.22'
assert_contains "$prompt_output" 'loopback'
expect_failure_with_input 'required-value EOF' '输入已结束' '' \
    prompt_required_value NODE_ID '节点 ID' '' validate_node_id

reset_inputs
cat >"$ENV_FILE" <<'ENV'
NACOS_USERNAME=stored-user
NACOS_PASSWORD=stored-password
ENV
NACOS_USERNAME='process-user'
NACOS_PASSWORD='process-password'
resolve_nacos_credentials </dev/null 2>"$prompt_output"
assert_equals "$NACOS_USERNAME" 'process-user'
assert_equals "$NACOS_PASSWORD" 'process-password'
[[ ! -s "$prompt_output" ]] || fail 'complete process credentials unexpectedly prompted'

reset_inputs
cat >"$ENV_FILE" <<'ENV'
NACOS_USERNAME=stored-user
NACOS_PASSWORD=stored-password
ENV
resolve_nacos_credentials </dev/null 2>"$prompt_output"
assert_equals "$NACOS_USERNAME" 'stored-user'
assert_equals "$NACOS_PASSWORD" 'stored-password'
[[ ! -s "$prompt_output" ]] || fail 'complete stored credentials unexpectedly prompted'

reset_inputs
cat >"$ENV_FILE" <<'ENV'
NACOS_USERNAME=
NACOS_PASSWORD=
ENV
if ! (resolve_nacos_credentials </dev/null 2>"$prompt_output"); then
    cat "$prompt_output" >&2
    fail 'stored unauthenticated mode was not reused'
fi
assert_equals "$NACOS_USERNAME" ''
assert_equals "$NACOS_PASSWORD" ''
[[ ! -s "$prompt_output" ]] || fail 'stored unauthenticated mode unexpectedly prompted'

reset_inputs
resolve_nacos_credentials 2>"$prompt_output" <<'INPUT'

INPUT
assert_equals "$NACOS_USERNAME" ''
assert_equals "$NACOS_PASSWORD" ''
assert_contains "$prompt_output" 'Nacos 用户名（直接回车表示无需认证）'

reset_inputs
resolve_nacos_credentials 2>"$prompt_output" <<'INPUT'
interactive-user

interactive-password
INPUT
assert_equals "$NACOS_USERNAME" 'interactive-user'
assert_equals "$NACOS_PASSWORD" 'interactive-password'
assert_contains "$prompt_output" '密码不能为空'
assert_not_contains "$prompt_output" 'interactive-password'
assert_contains "$SCRIPT" 'read -r -s'

reset_inputs
NACOS_USERNAME='process-user'
expect_failure_with_input 'partial process credentials' 'must be provided together' '' \
    resolve_nacos_credentials

reset_inputs
printf '%s\n' 'NACOS_PASSWORD=stored-password' >"$ENV_FILE"
expect_failure_with_input 'partial stored credentials' 'must be provided together' '' \
    resolve_nacos_credentials

reset_inputs
expect_failure_with_input 'username EOF' '输入已结束' '' resolve_nacos_credentials
expect_failure_with_input 'password EOF' '输入已结束' 'interactive-user
' resolve_nacos_credentials

printf 'PASS: install-node-nacos interactive input resolution\n'
