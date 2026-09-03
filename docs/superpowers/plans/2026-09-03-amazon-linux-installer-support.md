# Amazon Linux Installer Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every self-installing deployment script work on Amazon Linux 2 and Amazon Linux 2023 while preserving all existing distribution behavior.

**Architecture:** Keep each installer self-contained because users execute individual scripts directly from GitHub. Add an explicit `amzn` branch that installs Docker from the Amazon Linux repository, and use a pinned official Compose CLI plugin binary only when the native package does not produce a working `docker compose` command. A shared shell contract test will exercise the same public helper behavior in all four duplicated installers.

**Tech Stack:** Bash 4+, `/etc/os-release`, `dnf`/`yum`, systemd, Docker Engine, Docker Compose CLI plugin, shell contract tests.

---

### Task 1: Lock Amazon Linux Distribution And Package Behavior

**Files:**
- Create: `tests/test_amazon_linux_support.sh`
- Test: `install.sh`
- Test: `install-with-npm.sh`
- Test: `install-node.sh`
- Test: `install-node-nacos.sh`

- [ ] **Step 1: Write the failing distribution contract test**

Create `tests/test_amazon_linux_support.sh`. For each installer, source it with `INSTALLER_LIB_ONLY=1`, create a temporary `os-release` containing `ID=amzn`, set `OS_RELEASE_FILE` to the fixture, and assert:

```bash
assert_equals "$(detect_os)" amzn "$script must detect Amazon Linux"
```

Also create an unsupported `ID=unsupported` fixture and assert `detect_os` still exits nonzero with an error containing both `Unsupported Linux distribution` and `Amazon Linux`.

- [ ] **Step 2: Add failing native-package assertions**

Within an isolated subshell for each installer, replace `run_root` with a recorder, stub `command` so `dnf` is present, call `install_docker amzn`, and require the recorded command to contain:

```text
dnf install -y ca-certificates curl openssl docker
```

Require it not to contain `download.docker.com/linux/centos`. Repeat with only `yum` present and require:

```text
yum install -y ca-certificates curl openssl docker
```

Stub missing `curl` and `openssl`, call `ensure_host_tools amzn`, and assert the same selected native package manager installs `ca-certificates curl openssl`.

- [ ] **Step 3: Run the test and verify RED**

Run:

```bash
bash tests/test_amazon_linux_support.sh
```

Expected: FAIL because `detect_os` rejects `ID=amzn` before any package branch runs.

- [ ] **Step 4: Commit the failing contract**

```bash
git add tests/test_amazon_linux_support.sh
git commit -m "Define Amazon Linux installer compatibility" \
  -m "Constraint: Every remotely executable installer must remain self-contained" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Tested: bash tests/test_amazon_linux_support.sh (expected failure: amzn unsupported)"
```

### Task 2: Support Amazon Linux Docker And Host Tools

**Files:**
- Modify: `install.sh`
- Modify: `install-with-npm.sh`
- Modify: `install-node.sh`
- Modify: `install-node-nacos.sh`
- Test: `tests/test_amazon_linux_support.sh`

- [ ] **Step 1: Accept the Amazon Linux identifier**

In each `detect_os`, extend the exact-ID branch to:

```bash
ubuntu|debian|centos|rhel|rocky|almalinux|amzn)
```

Update the rejection message to end with:

```text
Supported: Ubuntu, Debian, CentOS, RHEL, Rocky Linux, AlmaLinux, Amazon Linux.
```

- [ ] **Step 2: Add a native package-manager selector**

Add the same helper to each installer:

```bash
amazon_linux_package_manager() {
    if command -v dnf >/dev/null 2>&1; then
        printf '%s\n' dnf
    elif command -v yum >/dev/null 2>&1; then
        printf '%s\n' yum
    else
        die 'Neither dnf nor yum is available on this Amazon Linux system.'
    fi
}
```

- [ ] **Step 3: Install Docker from the Amazon Linux repository**

Add this helper to each installer:

```bash
amazon_linux_install_docker() {
    local package_manager
    package_manager="$(amazon_linux_package_manager)"
    run_root "$package_manager" install -y ca-certificates curl openssl docker
}
```

Add an explicit `amzn)` case in `install_docker` which calls this helper. Do not call `rpm_install_docker`, add a repository, or request `docker-ce` for Amazon Linux.

- [ ] **Step 4: Install missing host tools natively**

Add an `amzn)` case in each `ensure_host_tools` which resolves `amazon_linux_package_manager` and runs:

```bash
run_root "$package_manager" install -y ca-certificates "${missing[@]}"
```

- [ ] **Step 5: Run the focused test**

Run:

```bash
bash tests/test_amazon_linux_support.sh
```

Expected: distribution, Docker package, and host-tool assertions pass; Compose assertions added in Task 3 may remain pending but must not be silently skipped.

- [ ] **Step 6: Commit the engine support**

```bash
git add install.sh install-with-npm.sh install-node.sh install-node-nacos.sh tests/test_amazon_linux_support.sh
git commit -m "Use Amazon Linux native Docker packages" \
  -m "Constraint: Support both Amazon Linux 2 and 2023 without a CentOS repository" \
  -m "Rejected: Docker CE CentOS repository | not a native supported Amazon Linux source" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Tested: bash tests/test_amazon_linux_support.sh"
```

### Task 3: Provide A Compose Plugin Fallback

**Files:**
- Modify: `tests/test_amazon_linux_support.sh`
- Modify: `install.sh`
- Modify: `install-with-npm.sh`
- Modify: `install-node.sh`
- Modify: `install-node-nacos.sh`

- [ ] **Step 1: Add failing Compose architecture and fallback tests**

For each installer, assert `docker_compose_arch` maps these values:

```text
x86_64 -> x86_64
amd64  -> x86_64
aarch64 -> aarch64
arm64   -> aarch64
```

Assert `s390x` fails. Override `machine_architecture`, `run_root`, `curl`, and `docker_cmd` so `ensure_compose amzn` simulates a failed native package attempt followed by a successful binary installation. Require:

```text
dnf install -y docker-compose-plugin
https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64
install -m 0755
/usr/local/lib/docker/cli-plugins/docker-compose
```

Repeat the URL assertion with `aarch64`. Assert unsupported architecture never invokes `curl` or `install`.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
bash tests/test_amazon_linux_support.sh
```

Expected: FAIL because `docker_compose_arch` and the Amazon Linux Compose fallback do not exist.

- [ ] **Step 3: Add deterministic Compose settings and validation**

Add these settings to each installer near the existing readonly defaults:

```bash
readonly DEFAULT_DOCKER_COMPOSE_VERSION='v2.40.3'
DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-$DEFAULT_DOCKER_COMPOSE_VERSION}"
```

Add helpers that validate the version with `^v[0-9]+\.[0-9]+\.[0-9]+$`, obtain `uname -m` through `machine_architecture`, and map only the four supported architecture spellings. Invalid versions and architectures must call `die` before a network request.

- [ ] **Step 4: Implement atomic official-plugin installation**

Implement `install_compose_plugin_binary` so it:

```bash
local plugin_dir='/usr/local/lib/docker/cli-plugins'
local plugin_path="$plugin_dir/docker-compose"
local temporary
temporary="$(mktemp)"
```

It must register a return trap to remove the temporary file, download with `curl -fL --retry 3 --connect-timeout 10`, create the plugin directory through `run_root install -d -m 0755`, and copy the completed file through `run_root install -m 0755`. The URL must be:

```text
https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${architecture}
```

- [ ] **Step 5: Add the Amazon Linux Compose flow**

In each `ensure_compose`, add an `amzn)` branch that:

1. selects `dnf` or `yum`;
2. attempts `run_root "$package_manager" install -y docker-compose-plugin` inside an `if` so `set -e` does not stop fallback;
3. returns if `docker_cmd compose version` now succeeds;
4. logs a warning when the native package is unavailable or ineffective;
5. calls `install_compose_plugin_binary`;
6. relies on the existing final `docker_cmd compose version` verification.

- [ ] **Step 6: Run focused and existing tests**

Run:

```bash
bash tests/test_amazon_linux_support.sh
bash tests/test_install_node_nacos.sh
bash tests/test_install_node_nacos_interactive.sh
bash tests/test_install_nacos_sidecar.sh
bash tests/test_install_apisix_nacos.sh
```

Expected: all tests PASS.

- [ ] **Step 7: Commit Compose support**

```bash
git add install.sh install-with-npm.sh install-node.sh install-node-nacos.sh tests/test_amazon_linux_support.sh
git commit -m "Keep Compose available on Amazon Linux hosts" \
  -m "The native Amazon Linux repositories do not consistently expose docker-compose-plugin across releases, so use a pinned official plugin binary only after the native attempt fails." \
  -m "Constraint: Support x86_64 and aarch64 hosts" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate" \
  -m "Tested: Amazon Linux contract and existing installer suites" \
  -m "Not-tested: Live package installation on EC2"
```

### Task 4: Verify The Complete Installer Set

**Files:**
- Verify: `install.sh`
- Verify: `install-with-npm.sh`
- Verify: `install-node.sh`
- Verify: `install-node-nacos.sh`
- Verify: `install-nacos-sidecar.sh`
- Verify: `install-apisix-nacos.sh`
- Verify: `tests/test_amazon_linux_support.sh`

- [ ] **Step 1: Run syntax checks**

```bash
bash -n install.sh install-with-npm.sh install-node.sh install-node-nacos.sh install-nacos-sidecar.sh install-apisix-nacos.sh tests/test_amazon_linux_support.sh
```

Expected: exit status 0 with no Bash syntax diagnostics.

- [ ] **Step 2: Run all repository tests**

```bash
bash tests/test_amazon_linux_support.sh
bash tests/test_install_node_nacos.sh
bash tests/test_install_node_nacos_interactive.sh
bash tests/test_install_nacos_sidecar.sh
bash tests/test_install_apisix_nacos.sh
```

Expected: every suite prints PASS and the Python registrar tests report OK.

- [ ] **Step 3: Run static checks**

```bash
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck install.sh install-with-npm.sh install-node.sh install-node-nacos.sh
fi
git diff --check master...HEAD
git status --short
```

Expected: no ShellCheck errors, no whitespace errors, and no uncommitted files.

- [ ] **Step 4: Review the final diff for scope**

```bash
git diff --stat master...HEAD
git diff master...HEAD -- install.sh install-with-npm.sh install-node.sh install-node-nacos.sh tests/test_amazon_linux_support.sh
```

Confirm only Amazon Linux detection, package installation, Compose fallback, and its test changed. Confirm Nacos registration, APISIX configuration, container definitions, ports, secrets, and enrollment flow are untouched.

- [ ] **Step 5: Record verification if follow-up edits were required**

If verification required a corrective edit, commit it using Lore trailers that state the exact failure and rerun evidence. Otherwise, do not create an empty commit.
