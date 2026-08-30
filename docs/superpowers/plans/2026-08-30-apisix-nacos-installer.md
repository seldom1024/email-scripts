# APISIX Nacos Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build an independent Docker Compose installer that runs APISIX with etcd, writes native Nacos discovery settings, and optionally starts APISIX Dashboard.

**Architecture:** `install-apisix-nacos.sh` owns all inputs, validation, file rendering, Docker checks, and lifecycle operations in a dedicated project directory. It generates APISIX's `config.yaml` with the Nacos v1-compatible discovery provider and a Compose file containing APISIX plus etcd; Dashboard is added only when explicitly enabled and uses its own generated `conf.yaml` against the shared etcd service. Existing node installers remain untouched.

**Tech Stack:** Bash 4+, Docker Engine, Docker Compose v2, Apache APISIX official image, etcd official image, optional APISIX Dashboard 3.x image, shell integration tests.

---

### Task 1: Lock the standalone installer contract with failing tests

**Files:**
- Create: `tests/test_install_apisix_nacos.sh`
- Test: `install-apisix-nacos.sh`

- [ ] **Step 1: Add library-mode test setup and assertions**

Source the installer with `INSTALLER_LIB_ONLY=1`, point `set_project_dir` at `mktemp -d`, and define `assert_contains`, `assert_not_contains`, `assert_equals`, and `expect_failure` helpers. The test must not invoke Docker or mutate the repository.

- [ ] **Step 2: Describe defaults and validation**

Set `NACOS_SERVER_URL='http://nacos.example.test:8848/nacos'`, `NACOS_SERVICE_NAME='outlook-email'`, `NACOS_NAMESPACE_ID='public'`, `NACOS_GROUP_NAME='DEFAULT_GROUP'`, empty credentials, and default ports. Assert the defaults are retained. Assert these invalid inputs fail: `ftp://nacos.example.test`, a URL with a query string, `bad service` as a service name, port `80` for a proxy port, port `70000`, an Admin API bind other than `127.0.0.1`, and a Dashboard password shorter than the configured minimum.

- [ ] **Step 3: Describe APISIX and Compose rendering**

Call `write_apisix_config`, `write_dashboard_config`, and `write_compose_file` with Dashboard disabled. Assert `config.yaml` contains:

```yaml
prefix: "/nacos/v1/"
fetch_interval: 30
```

Assert the Compose file contains `etcd` and `apisix`, does not contain `apisix-dashboard`, exposes `9080`, `9443`, and a localhost-bound `9180`, and mounts `./config.yaml` read-only. Enable Dashboard, render again, and assert it contains `apisix-dashboard`, port `9000`, and the generated Dashboard config mount.

- [ ] **Step 4: Describe secret and file safety**

Set credentials and an Admin Key containing shell-safe punctuation, render all files, and assert the values occur only in the expected mode-`600` files. Assert no password appears in a command string or log helper output. Assert Dashboard credentials are rendered only when Dashboard is enabled.

- [ ] **Step 5: Run the test to verify RED**

Run:

```bash
bash tests/test_install_apisix_nacos.sh
```

Expected result: FAIL because `install-apisix-nacos.sh` does not exist.

- [ ] **Step 6: Commit the failing contract**

```bash
git add tests/test_install_apisix_nacos.sh
git commit -m "Define the standalone APISIX Nacos installer contract"
```

The commit body must include Lore trailers for the Nacos v1 compatibility constraint, isolated scope, and the intentionally failing test.

### Task 2: Implement inputs, validation, and secure configuration rendering

**Files:**
- Create: `install-apisix-nacos.sh`
- Test: `tests/test_install_apisix_nacos.sh`

- [ ] **Step 1: Add library-safe shell structure**

Create `INSTALLER_LIB_ONLY` handling, `set -Eeuo pipefail`, project paths, image/version defaults, and functions `log`, `warn`, `die`, `set_project_dir`, `required_value`, `validate_url`, `validate_identifier`, `validate_port`, and `validate_nacos_credentials`. Keep all generated files under the selected project directory.

- [ ] **Step 2: Add interactive resolution and CLI options**

Support `--project-dir`, `--nacos-url`, `--nacos-service`, `--nacos-namespace`, `--nacos-group`, `--nacos-username`, `--nacos-password`, `--http-port`, `--https-port`, `--admin-port`, `--dashboard`, and `--dashboard-port`. Prompt for missing Nacos URL and service name. Prompt for Nacos username with Enter meaning unauthenticated; read the password silently when the username is non-empty. Prompt whether to enable Dashboard; when enabled, read a non-empty hidden Dashboard password. Reuse existing `.env` values on reruns and reject partial credential pairs.

- [ ] **Step 3: Generate APISIX configuration**

Render `config.yaml` with APISIX traditional/etcd mode, the selected listen ports, a generated or supplied Admin Key, localhost Admin API allowlist, etcd endpoint `http://etcd:2379`, and Nacos discovery:

```yaml
discovery:
  nacos:
    host:
      - "http://[user:password@]nacos-host:8848"
    prefix: "/nacos/v1/"
    fetch_interval: 30
```

Use validated values only, escape YAML-sensitive characters, write to a temporary file, move it into place, and set mode `600` because Nacos credentials may be embedded in the host URL.

- [ ] **Step 4: Generate optional Dashboard configuration**

When enabled, render `dashboard-conf.yaml` using the Dashboard 3.x schema: listen on `0.0.0.0:9000` inside the container, connect to `etcd:2379`, and create exactly one configured user with the prompted password and a generated JWT secret. Publish the host port on `127.0.0.1` by default so access requires local login or an SSH tunnel. Set mode `600`; do not generate or mount this file when Dashboard is disabled.

- [ ] **Step 5: Run the contract test to verify GREEN**

Run:

```bash
bash tests/test_install_apisix_nacos.sh
```

Expected result: all rendering, defaults, validation, and file-permission assertions pass.

- [ ] **Step 6: Commit the renderer**

```bash
git add install-apisix-nacos.sh tests/test_install_apisix_nacos.sh
git commit -m "Render secure APISIX and Nacos discovery configuration"
```

### Task 3: Implement Docker Compose lifecycle and optional Dashboard

**Files:**
- Modify: `install-apisix-nacos.sh`
- Test: `tests/test_install_apisix_nacos.sh`

- [ ] **Step 1: Render the Compose topology**

Generate `docker-compose.yml` with an `etcd` service using a persistent `./data/etcd` bind mount, an `apisix` service depending on etcd, and an optional `apisix-dashboard` service. Use pinned image variables, read-only config mounts, restart policies, and explicit port mappings. Bind the host Admin API as `127.0.0.1:${APISIX_ADMIN_PORT}:9180`; bind Dashboard as `127.0.0.1:${DASHBOARD_PORT}:9000` only when enabled.

- [ ] **Step 2: Add Docker and Compose preflight checks**

Implement `require_linux`, `require_privileges`, `ensure_docker`, `ensure_compose`, and `compose_cmd`. Fail before writing deployment files when Docker or the Compose v2 plugin cannot be installed or used. Never remove unrelated containers or run a broad cleanup command.

- [ ] **Step 3: Add validation and startup**

Implement `validate_compose` with `docker compose config -q`, then `refresh_and_start` using `docker compose up -d --remove-orphans` only for this project. Run a bounded readiness check against `http://127.0.0.1:${APISIX_HTTP_PORT}` and print service status without printing credentials or the full Admin Key.

- [ ] **Step 4: Add bounded diagnostics**

On failure, print `docker compose ps` and the last 100 lines of APISIX/etcd/Dashboard logs, filtering any configured password, Nacos URL credentials, JWT secret, and Admin Key before output.

- [ ] **Step 5: Extend tests for lifecycle-safe rendering**

In library mode, stub `compose_cmd` and assert the generated command sequence is `config -q` followed by `up -d --remove-orphans`. Assert Dashboard-disabled runs do not mention the Dashboard service and Dashboard-enabled runs include it. Assert a rerun preserves an existing `.env` value unless a CLI option explicitly overrides it.

- [ ] **Step 6: Commit the Compose lifecycle**

```bash
git add install-apisix-nacos.sh tests/test_install_apisix_nacos.sh
git commit -m "Deploy APISIX and optional Dashboard with Compose"
```

### Task 4: Complete verification and operator documentation

**Files:**
- Modify: `install-apisix-nacos.sh`
- Modify: `tests/test_install_apisix_nacos.sh`
- Create: `docs/superpowers/plans/2026-08-30-apisix-nacos-installer-operations.md`

- [ ] **Step 1: Add usage output and operator instructions**

Document the interactive command, unattended flags, generated paths, default ports, Dashboard enablement, and the required APISIX Upstream shape:

```json
{
  "service_name": "outlook-email",
  "discovery_type": "nacos",
  "discovery_args": {
    "namespace_id": "public",
    "group_name": "DEFAULT_GROUP"
  }
}
```

State that the script does not create routes, that all business nodes must share `outlook-email`, and that Nacos data migration is outside this installer.

- [ ] **Step 2: Run complete verification**

Run:

```bash
bash -n install-apisix-nacos.sh
bash -n install-node.sh
bash -n install-node-nacos.sh
bash tests/test_install_apisix_nacos.sh
bash tests/test_install_node_nacos.sh
bash tests/test_install_node_nacos_interactive.sh
git diff --check HEAD~3..HEAD
```

Then scan the new installer and tests:

```bash
if rg -n '(api\.ipify\.org|ifconfig\.me|--nacos-password|APISIX_ADMIN_KEY=.{0,20}[A-Za-z0-9])' install-apisix-nacos.sh; then exit 1; fi
if rg -n '0\.0\.0\.0:9180|"0\.0\.0\.0".*9180|admin.*public' install-apisix-nacos.sh; then exit 1; fi
```

- [ ] **Step 3: Commit documentation and final fixes**

```bash
git add install-apisix-nacos.sh tests/test_install_apisix_nacos.sh docs/superpowers/plans/2026-08-30-apisix-nacos-installer-operations.md
git commit -m "Document APISIX Nacos installer operations"
```

The final report must distinguish verified local rendering from untested live Docker, Nacos, and Dashboard startup.
