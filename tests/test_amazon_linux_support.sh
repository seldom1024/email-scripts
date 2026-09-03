#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equals() {
    local actual="$1" expected="$2" message="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$message (expected '$expected', got '$actual')"
}

assert_contains() {
    local value="$1" expected="$2" message="$3"
    [[ "$value" == *"$expected"* ]] \
        || fail "$message (missing '$expected')"
}

assert_not_contains() {
    local value="$1" unexpected="$2" message="$3"
    [[ "$value" != *"$unexpected"* ]] \
        || fail "$message (unexpected '$unexpected')"
}

write_os_release() {
    local file="$1" id="$2"
    printf 'ID=%s\nNAME=Test\n' "$id" >"$file"
}

run_contract_for_installer() (
    local installer="$1"
    local case_dir="$TEST_TMP/${installer%.sh}"
    local amzn_release="$case_dir/os-release-amzn"
    local unsupported_release="$case_dir/os-release-unsupported"
    local command_log="$case_dir/commands.log"
    local output

    mkdir -p "$case_dir"
    write_os_release "$amzn_release" amzn
    write_os_release "$unsupported_release" unsupported

    export INSTALLER_LIB_ONLY=1
    # shellcheck disable=SC1090
    source "$ROOT_DIR/$installer"

    OS_RELEASE_FILE="$amzn_release"
    assert_equals "$(detect_os)" amzn "$installer must detect Amazon Linux"

    if output="$(OS_RELEASE_FILE="$unsupported_release" detect_os 2>&1)"; then
        fail "$installer must still reject unsupported distributions"
    fi
    assert_contains "$output" 'Unsupported Linux distribution' \
        "$installer must retain its unsupported-distribution error"
    assert_contains "$output" 'Amazon Linux' \
        "$installer must list Amazon Linux as supported"

    declare -F amazon_linux_package_manager >/dev/null \
        || fail "$installer must define amazon_linux_package_manager"
    declare -F amazon_linux_install_docker >/dev/null \
        || fail "$installer must define amazon_linux_install_docker"

    AVAILABLE_PACKAGE_MANAGER=dnf
    HOST_TOOLS_MISSING=0
    command() {
        if [[ "${1:-}" == '-v' ]]; then
            case "${2:-}" in
                dnf) [[ "$AVAILABLE_PACKAGE_MANAGER" == dnf ]] ;;
                yum) [[ "$AVAILABLE_PACKAGE_MANAGER" == yum ]] ;;
                curl|openssl) ((HOST_TOOLS_MISSING == 0)) ;;
                *) builtin command "$@" ;;
            esac
            return
        fi
        builtin command "$@"
    }
    run_root() {
        printf '%s\n' "$*" >>"$command_log"
    }

    : >"$command_log"
    install_docker amzn
    output="$(<"$command_log")"
    assert_contains "$output" 'dnf install -y ca-certificates curl openssl docker' \
        "$installer must install Docker with dnf on Amazon Linux"
    assert_not_contains "$output" 'download.docker.com/linux/centos' \
        "$installer must not add the CentOS Docker repository on Amazon Linux"

    AVAILABLE_PACKAGE_MANAGER=yum
    : >"$command_log"
    install_docker amzn
    output="$(<"$command_log")"
    assert_contains "$output" 'yum install -y ca-certificates curl openssl docker' \
        "$installer must install Docker with yum on Amazon Linux"
    assert_not_contains "$output" 'download.docker.com/linux/centos' \
        "$installer must not add the CentOS Docker repository on Amazon Linux"

    AVAILABLE_PACKAGE_MANAGER=dnf
    HOST_TOOLS_MISSING=1
    : >"$command_log"
    ensure_host_tools amzn
    output="$(<"$command_log")"
    assert_contains "$output" 'dnf install -y ca-certificates curl openssl' \
        "$installer must install missing host tools with dnf"

    AVAILABLE_PACKAGE_MANAGER=yum
    : >"$command_log"
    ensure_host_tools amzn
    output="$(<"$command_log")"
    assert_contains "$output" 'yum install -y ca-certificates curl openssl' \
        "$installer must install missing host tools with yum"
)

installers=(
    install.sh
    install-with-npm.sh
    install-node.sh
    install-node-nacos.sh
)

for installer in "${installers[@]}"; do
    run_contract_for_installer "$installer"
done

printf 'PASS: Amazon Linux installer compatibility\n'
