# Interactive Nacos Node Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `install-node-nacos.sh` securely prompt for missing master, node, Nacos, advertised-IP, and optional Nacos credential values while preserving unattended CLI installs.

**Architecture:** Keep argument parsing and deployment unchanged, but insert a pure input-resolution phase after the installation directory is known and before host mutation begins. A reusable required-value prompt applies existing validators in a recoverable subshell, while a dedicated credential resolver enforces environment, `.env`, then interactive precedence and uses silent password input.

**Tech Stack:** Bash, existing shell test harness, Python standard-library registrar tests

---

### Task 1: Lock the interactive contract with failing tests

**Files:**
- Create: `tests/test_install_node_nacos_interactive.sh`
- Test: `install-node-nacos.sh`

- [ ] **Step 1: Add a library-mode interactive test harness**

Create a shell test that sources `install-node-nacos.sh`, builds a temporary `.env`, resets all input globals between cases, and provides `assert_equals`, `assert_contains`, and `expect_failure_with_output` helpers. Test these exact behaviors:

```bash
# CLI values are retained without reading stdin.
MASTER_URL='https://cli-master.example.test/'
NODE_ID='replica-cli'
MASTER_FINGERPRINT="SHA256:$(printf 'a%.0s' {1..64})"
NACOS_SERVER_URL='https://cli-nacos.example.test:8848/nacos/'
NACOS_SERVICE_NAME='cli-service'
NACOS_ADVERTISE_IP='198.51.100.20'
resolve_install_inputs </dev/null
assert_equals "$MASTER_URL" 'https://cli-master.example.test'
assert_equals "$NACOS_SERVER_URL" 'https://cli-nacos.example.test:8848/nacos'

# Existing .env values appear as defaults and Enter accepts them.
printf '%s\n' \
    'MASTER_URL=https://env-master.example.test/' \
    'NACOS_SERVER_URL=https://env-nacos.example.test:8848/nacos/' \
    'NACOS_SERVICE_NAME=env-service' \
    'NACOS_ADVERTISE_IP=198.51.100.21' >"$ENV_FILE"
resolve_install_inputs <<INPUT

replica-env
SHA256:$(printf 'b%.0s' {1..64})



INPUT
assert_equals "$MASTER_URL" 'https://env-master.example.test'
assert_equals "$NACOS_SERVICE_NAME" 'env-service'

# Invalid interactive input is retried and EOF is explicit.
NACOS_ADVERTISE_IP=''
prompt_required_value NACOS_ADVERTISE_IP '注册 IP' NACOS_ADVERTISE_IP validate_ipv4 <<INPUT
127.0.0.1
198.51.100.22
INPUT
assert_equals "$NACOS_ADVERTISE_IP" '198.51.100.22'
expect_failure_with_output 'EOF' '输入已结束' \
    prompt_required_value NODE_ID '节点 ID' '' validate_node_id </dev/null
```

Add credential cases for a complete process pair, a complete `.env` pair, unauthenticated Enter, a non-empty username with an empty-then-valid hidden password, process and `.env` partial-pair failures, and an assertion that captured prompt output never contains the password.

- [ ] **Step 2: Run the new test and verify RED**

Run: `bash tests/test_install_node_nacos_interactive.sh`

Expected: FAIL because `resolve_install_inputs` and `prompt_required_value` do not exist and `resolve_nacos_credentials` lacks the interactive branch.

- [ ] **Step 3: Commit the verified failing tests**

```bash
git add tests/test_install_node_nacos_interactive.sh
git commit -m "Define secure interactive installer behavior" -m "The installer needs executable coverage for CLI precedence, reusable defaults, retry behavior, EOF handling, and credential secrecy before input handling changes.\n\nConstraint: Passwords must never be command-line arguments or echoed\nConfidence: high\nScope-risk: narrow\nTested: New test fails because interactive resolver functions are absent\nNot-tested: Production implementation is added in the next commit"
```

### Task 2: Implement validated input and credential resolution

**Files:**
- Modify: `install-node-nacos.sh:397`
- Modify: `install-node-nacos.sh:947`
- Modify: `install-node-nacos.sh:969`
- Test: `tests/test_install_node_nacos_interactive.sh`

- [ ] **Step 1: Add reusable single-value validators and prompt resolution**

Add one-argument validator wrappers for Nacos service names and these helpers after `read_env_value`:

```bash
validate_nacos_service_name() {
    validate_nacos_identifier service "$1"
}

prompt_required_value() {
    local variable_name="$1" label="$2" env_key="$3" validator="$4"
    local current default_value='' entered candidate validation_output
    current="${!variable_name}"
    if [[ -n "$current" ]]; then
        "$validator" "$current"
        return 0
    fi
    if [[ -n "$env_key" ]]; then
        default_value="$(read_env_value "$ENV_FILE" "$env_key" || true)"
    fi
    while true; do
        if [[ -n "$default_value" ]]; then
            printf '%s [%s]: ' "$label" "$default_value" >&2
        else
            printf '%s: ' "$label" >&2
        fi
        IFS= read -r entered || die "输入已结束，未能读取${label}。"
        candidate="$entered"
        [[ -n "$candidate" ]] || candidate="$default_value"
        if [[ -z "$candidate" ]]; then
            warn "${label}不能为空。"
            continue
        fi
        if validation_output="$("$validator" "$candidate" 2>&1)"; then
            printf -v "$variable_name" '%s' "$candidate"
            return 0
        fi
        warn "${validation_output#*ERROR: }"
    done
}

resolve_install_inputs() {
    prompt_required_value MASTER_URL '主节点地址' MASTER_URL validate_master_url
    MASTER_URL="$(normalize_master_url "$MASTER_URL")"
    prompt_required_value NODE_ID '节点 ID' '' validate_node_id
    prompt_required_value MASTER_FINGERPRINT '主节点指纹' '' validate_master_fingerprint
    prompt_required_value NACOS_SERVER_URL 'Nacos 地址' NACOS_SERVER_URL validate_nacos_url
    NACOS_SERVER_URL="$(normalize_nacos_url "$NACOS_SERVER_URL")"
    prompt_required_value NACOS_SERVICE_NAME 'Nacos 服务名' NACOS_SERVICE_NAME validate_nacos_service_name
    prompt_required_value NACOS_ADVERTISE_IP '注册 IP' NACOS_ADVERTISE_IP validate_ipv4
}
```

- [ ] **Step 2: Extend credential resolution without exposing passwords**

Replace `resolve_nacos_credentials` so it validates a supplied process pair first, rejects partial pairs, then loads and validates an existing `.env` pair, otherwise prompts for `Nacos 用户名（直接回车表示无需认证）`. If the username is non-empty, loop on `IFS= read -r -s NACOS_PASSWORD`, print only a newline after the silent read, reject empty passwords, validate both values in a recoverable subshell, and retry invalid interactive credentials. Any EOF must call `die` with a Chinese message naming the unfinished field.

- [ ] **Step 3: Reorder main before any host changes**

Move `set_project_dir "$project_dir_arg"` ahead of input validation, call `resolve_install_inputs`, validate namespace/group/cluster, then call `resolve_nacos_credentials`. Remove the six immediate `--... is required` failures and their duplicate validators. Keep all calls to `require_linux_systemd`, privilege checks, package installation, file generation, enrollment, and startup after resolution.

- [ ] **Step 4: Document the optional interactive interface**

Change the usage synopsis to `[--master URL] [--node-id ID] [--master-fingerprint FINGERPRINT] [--nacos-url URL] [--nacos-service NAME] [--advertise-ip IPv4] [options]`. State that omitted values are prompted, existing `.env` deployment values are offered as defaults, and Nacos username/password can be entered interactively with an empty username selecting unauthenticated mode.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run: `bash -n install-node-nacos.sh && bash tests/test_install_node_nacos_interactive.sh`

Expected: syntax check exits 0 and every interactive case prints `PASS: install-node-nacos interactive input resolution`.

### Task 3: Preserve existing contracts and complete verification

**Files:**
- Modify: `tests/test_install_node_nacos.sh`
- Test: `tests/test_install_node_nacos.sh`
- Test: `tests/test_install_node_nacos_interactive.sh`
- Test: `tests/test_nacos_registrar.py`

- [ ] **Step 1: Update the existing credential regression**

Adjust the existing library test so calling `resolve_nacos_credentials` for `.env` reuse does not have an available process pair, and retain the partial credential failure assertions. Add static assertions that no `--nacos-password` option exists and the implementation contains silent password input.

- [ ] **Step 2: Run all functional verification**

Run:

```bash
bash -n install-node.sh
bash -n install-node-nacos.sh
bash tests/test_install_node_nacos.sh
bash tests/test_install_node_nacos_interactive.sh
```

The existing shell contract test generates a registrar in its temporary project and invokes `tests/test_nacos_registrar.py` against it. Expected: both syntax checks exit 0, both shell suites print PASS, and the nested registrar suite reports two passing tests.

- [ ] **Step 3: Run repository safety and formatting checks**

Run:

```bash
git diff --check
if grep -Il $'\r' install-node-nacos.sh tests/test_install_node_nacos.sh tests/test_install_node_nacos_interactive.sh; then exit 1; fi
if rg -n '(api\.ipify\.org|ifconfig\.me|--nacos-password|APISIX_ADMIN_KEY)' install-node-nacos.sh; then exit 1; fi
```

Expected: no whitespace errors, no CRLF matches, and no prohibited public-IP discovery, password flag, or APISIX key in the installer.

- [ ] **Step 4: Review the final diff against the design**

Check `git diff --stat`, `git diff -- install-node-nacos.sh tests`, and `git status --short`. Confirm CLI values bypass prompts, `.env` values are only defaults when CLI is absent, credentials follow the required three-level precedence, all prompt validation happens before host changes, and no unrelated files changed.

- [ ] **Step 5: Commit the implementation**

```bash
git add install-node-nacos.sh tests/test_install_node_nacos.sh tests/test_install_node_nacos_interactive.sh
git commit -m "Allow operators to complete replica configuration interactively" -m "Missing deployment values now use validated prompts with reusable .env defaults, while complete CLI and environment input retains unattended behavior. Nacos passwords use silent input and are never accepted as arguments.\n\nConstraint: Preserve the unchanged third-party business image and pre-deployment validation\nRejected: Persist node enrollment secrets in .env | node ID and fingerprint are only needed for enrollment\nConfidence: high\nScope-risk: moderate\nDirective: Keep credential prompts silent and input resolution before host mutation\nTested: Bash syntax, shell contract and interactive suites, Python registrar lifecycle, diff and sensitive-data scans\nNot-tested: Live Nacos and APISIX deployment"
```
