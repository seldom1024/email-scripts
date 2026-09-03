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

    declare -F docker_compose_arch >/dev/null \
        || fail "$installer must define docker_compose_arch"
    declare -F install_compose_plugin_binary >/dev/null \
        || fail "$installer must define install_compose_plugin_binary"

    TEST_ARCH=x86_64
    machine_architecture() { printf '%s\n' "$TEST_ARCH"; }
    assert_equals "$(docker_compose_arch)" x86_64 \
        "$installer must support x86_64 Compose binaries"
    TEST_ARCH=amd64
    assert_equals "$(docker_compose_arch)" x86_64 \
        "$installer must normalize amd64 Compose binaries"
    TEST_ARCH=aarch64
    assert_equals "$(docker_compose_arch)" aarch64 \
        "$installer must support aarch64 Compose binaries"
    TEST_ARCH=arm64
    assert_equals "$(docker_compose_arch)" aarch64 \
        "$installer must normalize arm64 Compose binaries"
    TEST_ARCH=s390x
    if output="$(docker_compose_arch 2>&1)"; then
        fail "$installer must reject unsupported Compose architectures"
    fi
    assert_contains "$output" 'Unsupported architecture' \
        "$installer must explain unsupported Compose architectures"

    TEST_ARCH=x86_64
    AVAILABLE_PACKAGE_MANAGER=dnf
    HOST_TOOLS_MISSING=0
    PACKAGE_INSTALL_FAILS=0
    CHECKSUM_MATCHES=1
    : >"$command_log"
    docker_cmd() {
        if [[ "${1:-}" == compose && "${2:-}" == version ]]; then
            grep -q '/usr/local/lib/docker/cli-plugins/docker-compose' "$command_log"
            return
        fi
        return 0
    }
    curl() {
        local argument output_file='' url='' binary_hash
        printf 'curl %s\n' "$*" >>"$command_log"
        while (($#)); do
            argument="$1"
            shift
            if [[ "$argument" == '--output' || "$argument" == '-o' ]]; then
                (($#)) || fail "$installer curl stub received no output path"
                output_file="$1"
                shift
            else
                url="$argument"
            fi
        done
        [[ -n "$output_file" ]] || fail "$installer curl stub received no output path"
        if [[ "$url" == */checksums.txt ]]; then
            binary_hash="$(printf 'compose-binary\n' | sha256sum | awk '{print $1}')"
            if ((CHECKSUM_MATCHES == 0)); then
                binary_hash='0000000000000000000000000000000000000000000000000000000000000000'
            fi
            printf '%s *docker-compose-linux-x86_64\n' "$binary_hash" >"$output_file"
            printf '%s *docker-compose-linux-aarch64\n' "$binary_hash" >>"$output_file"
        else
            printf 'compose-binary\n' >"$output_file"
        fi
    }
    run_root() {
        printf '%s\n' "$*" >>"$command_log"
        if ((PACKAGE_INSTALL_FAILS == 1)) \
            && [[ "${1:-}" == dnf || "${1:-}" == yum ]] \
            && [[ "${2:-}" == install && "${4:-}" == docker-compose-plugin ]]; then
            return 1
        fi
    }

    ensure_compose amzn
    output="$(<"$command_log")"
    assert_contains "$output" 'dnf install -y docker-compose-plugin' \
        "$installer must try the native Compose package first"
    assert_contains "$output" \
        "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" \
        "$installer must download the x86_64 official Compose plugin"
    assert_contains "$output" \
        "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/checksums.txt" \
        "$installer must download the official Compose checksums"
    assert_contains "$output" 'install -m 0755' \
        "$installer must install the Compose plugin executable"
    assert_contains "$output" '/usr/local/lib/docker/cli-plugins/docker-compose' \
        "$installer must use the system-wide Compose plugin path"

    TEST_ARCH=aarch64
    AVAILABLE_PACKAGE_MANAGER=yum
    PACKAGE_INSTALL_FAILS=1
    : >"$command_log"
    ensure_compose amzn
    output="$(<"$command_log")"
    assert_contains "$output" 'yum install -y docker-compose-plugin' \
        "$installer must try the native Compose package with yum"
    assert_contains "$output" \
        "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-aarch64" \
        "$installer must fall back to the aarch64 Compose binary when the native package fails"

    TEST_ARCH=x86_64
    PACKAGE_INSTALL_FAILS=0
    CHECKSUM_MATCHES=0
    : >"$command_log"
    if output="$(install_compose_plugin_binary 2>&1)"; then
        fail "$installer must reject a Compose binary with a mismatched checksum"
    fi
    assert_contains "$output" 'checksum verification failed' \
        "$installer must explain a Compose checksum mismatch"
    assert_not_contains "$(<"$command_log")" 'install -d -m 0755' \
        "$installer must not create the root plugin directory after a checksum mismatch"
    assert_not_contains "$(<"$command_log")" 'install -m 0755' \
        "$installer must not install a Compose binary after a checksum mismatch"

    TEST_ARCH=s390x
    CHECKSUM_MATCHES=1
    : >"$command_log"
    if output="$(install_compose_plugin_binary 2>&1)"; then
        fail "$installer must not install Compose for an unsupported architecture"
    fi
    assert_not_contains "$(<"$command_log")" 'curl ' \
        "$installer must reject unsupported architecture before download"
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
