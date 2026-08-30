# Standalone Nacos Sidecar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an independent `install-nacos-sidecar.sh` that registers an already-deployed business service in Nacos without modifying either historical node installer or the business container.

**Architecture:** The new installer owns a dedicated `./mail-nacos-sidecar` project directory, `.env`, registrar source, and one-service Docker Compose file. The registrar runs with Linux host networking so its readiness check at `127.0.0.1:5000` reaches the existing host-published service. It reuses the proven Nacos v1-compatible registration, heartbeat, auth-refresh, readiness, and deregistration behavior, but has no business-service definition or lifecycle command.

**Tech Stack:** Bash 4+, Docker Engine, Docker Compose v2, `python:3.12-alpine`, Nacos 2.x-compatible v1 HTTP API, shell integration tests, and the existing registrar lifecycle test conventions.

---

### Task 1: Lock the Sidecar contract with failing tests

**Files:**
- Create: `tests/test_install_nacos_sidecar.sh`
- Test: `install-nacos-sidecar.sh`

- [ ] **Step 1: Add library-mode setup and assertion helpers**

Source `install-nacos-sidecar.sh` with `INSTALLER_LIB_ONLY=1`, set the project directory to a temporary path, and define `assert_contains`, `assert_not_contains`, `assert_equals`, `assert_mode_600`, and `expect_failure`. The test must never start Docker or write into the repository.

- [ ] **Step 2: Assert defaults and exact interactive contract**

Initialize the library and assert:

```text
DEFAULT_NACOS_SERVICE_NAME=mail-cluster
DEFAULT_NACOS_NAMESPACE_ID=public
DEFAULT_NACOS_GROUP_NAME=DEFAULT_GROUP
DEFAULT_NACOS_CLUSTER_NAME=DEFAULT
DEFAULT_ADVERTISE_PORT=5000
DEFAULT_READY_URL=http://127.0.0.1:5000/health/ready
DEFAULT_PROJECT_DIR=./mail-nacos-sidecar
```

Stub input with an empty `--advertise-ip` value and capture stderr. Assert the prompt contains the exact text `注册ip:`. Assert the installer source contains no public IP lookup URL such as `api.ipify.org` or `ifconfig.me`.

- [ ] **Step 3: Assert validation boundaries**

Set valid values and assert these validators succeed: `http://nacos.example.test:8848/nacos`, `198.51.100.20`, service `mail-cluster`, namespace `public`, group `DEFAULT_GROUP`, cluster `DEFAULT`, port `5000`, and readiness URL `http://127.0.0.1:5000/health/ready`.

Assert these inputs fail: `ftp://nacos.example.test`, a URL with a query string, `198.51.100.999`, loopback or unspecified advertise IP, service name containing whitespace, port `80`, port `70000`, readiness URL with a query string, and partial Nacos credentials. Assert that `--nacos-password` is absent from the installer usage and parser.

- [ ] **Step 4: Assert isolated Compose rendering**

Call `prepare_env`, `write_registrar_file`, and `write_compose_file`. Assert the Compose file contains exactly one `nacos-registrar` service, `network_mode: host`, `image: python:3.12-alpine`, the generated registrar mount, and the readiness URL environment variable. Assert it does not contain `outlook-mail-replica`, `outlook-email`, `ports:`, or any business image/container definition.

- [ ] **Step 5: Assert secrets and file permissions**

Render with authenticated Nacos credentials and a shell-safe password. Assert credentials occur in `.env` and the generated registrar environment references, never in test log output or a command-line password option. Assert `.env`, `nacos/registrar.py`, and `docker-compose.yml` have mode `600` (the registrar file may be executable only through the container command, not by permission broadening).

- [ ] **Step 6: Run the test to verify RED**

Run:

```bash
bash tests/test_install_nacos_sidecar.sh
```

Expected result: FAIL because `install-nacos-sidecar.sh` does not exist.

- [ ] **Step 7: Commit the failing contract**

```bash
git add tests/test_install_nacos_sidecar.sh
git commit -m "Define the standalone Nacos Sidecar contract"
```

Include Lore trailers recording the existing-service boundary, host-network requirement, default `mail-cluster` service name, and intentionally failing test.

### Task 2: Implement secure inputs, persistence, and registrar extraction

**Files:**
- Create: `install-nacos-sidecar.sh`
- Test: `tests/test_install_nacos_sidecar.sh`

- [ ] **Step 1: Add library-safe shell structure and project paths**

Create the Bash entrypoint with `set -Eeuo pipefail`, `umask 077`, `INSTALLER_LIB_ONLY` handling, and these paths derived by `set_project_dir`:

```bash
PROJECT_DIR
DATA_DIR
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
REGISTRAR_FILE="$PROJECT_DIR/nacos/registrar.py"
```

Set the default project directory to `./mail-nacos-sidecar`, resolve it with `cd -P`, and keep every generated file below that directory.

- [ ] **Step 2: Implement validators and secret-safe helpers**

Implement `validate_nacos_url`, `validate_nacos_identifier`, `validate_ipv4`, `validate_port`, `validate_ready_url`, `validate_nacos_credentials`, `validate_env_value`, `read_env_value`, `env_file_has_key`, `upsert_env_var`, `generate_secret`, `log`, `warn`, and `die`. URLs must be HTTP(S), host/port plus optional `/nacos`, and have no query or fragment. Identifiers must use letters, digits, dot, dash, or underscore. Reject partial credential pairs and newlines. Never print password values.

- [ ] **Step 3: Implement CLI and interactive resolution**

Support exactly these options:

```text
--project-dir PATH
--nacos-url URL
--nacos-service NAME
--advertise-ip IPV4
--advertise-port PORT
--ready-url URL
--nacos-namespace ID
--nacos-group NAME
--nacos-cluster NAME
--nacos-username USER
-h, --help
```

Resolve values in this order: explicit CLI value, existing `.env` value, documented default, then prompt. When the IP is still missing, prompt `注册ip:` and validate the entered IPv4 address. Prompt Nacos username with Enter meaning unauthenticated; read the password with `read -r -s` when a username is present. Do not add a `--nacos-password` option. Allow `NACOS_PASSWORD` from the process environment for unattended authentication.

- [ ] **Step 4: Extract the existing registrar implementation without changing historical files**

Copy the self-contained Python registrar logic currently embedded in `install-node-nacos.sh` into a heredoc written by `write_registrar_file`. Preserve these Nacos v1 paths and lifecycle methods:

```text
/nacos/v1/auth/users/login
/nacos/v1/ns/instance
/nacos/v1/ns/instance/beat
```

Preserve readiness polling against `REPLICA_READY_URL`, bounded retry backoff, access-token refresh, heartbeat recovery, and final deregistration. Parameterize only environment variables; do not introduce a business container name or change `install-node-nacos.sh`.

- [ ] **Step 5: Run the contract test to verify GREEN**

Run:

```bash
bash -n install-nacos-sidecar.sh
bash tests/test_install_nacos_sidecar.sh
```

Expected result: all input, default, registrar, isolation, and permission assertions pass.

- [ ] **Step 6: Commit the input and registrar implementation**

```bash
git add install-nacos-sidecar.sh tests/test_install_nacos_sidecar.sh
git commit -m "Extract a standalone Nacos registrar Sidecar"
```

Use Lore trailers to record that the registrar is copied from the proven implementation while historical installers remain untouched.

### Task 3: Add host-network Compose lifecycle and preflight checks

**Files:**
- Modify: `install-nacos-sidecar.sh`
- Test: `tests/test_install_nacos_sidecar.sh`

- [ ] **Step 1: Render the one-service Compose project**

Generate `docker-compose.yml` with only this service shape:

```yaml
services:
  nacos-registrar:
    image: python:3.12-alpine
    network_mode: host
    command: ["python", "/app/registrar.py"]
    volumes:
      - ./nacos/registrar.py:/app/registrar.py:ro
    environment:
      - NACOS_SERVER_URL=${NACOS_SERVER_URL}
      - NACOS_SERVICE_NAME=${NACOS_SERVICE_NAME}
      - NACOS_ADVERTISE_IP=${NACOS_ADVERTISE_IP}
      - NACOS_ADVERTISE_PORT=${NACOS_ADVERTISE_PORT}
      - REPLICA_READY_URL=${REPLICA_READY_URL}
    restart: unless-stopped
```

Include namespace, group, cluster, username, and password environment references, but do not put literal credentials in the Compose file. Do not define `ports`, `depends_on`, a business image, or a business container.

- [ ] **Step 2: Add host readiness preflight**

Implement `check_ready_endpoint` using `curl --connect-timeout 5 --max-time 5` against `REPLICA_READY_URL`. Run this check after input validation and before writing deployment files or starting Docker. A failed check must explain the URL and exit without touching the existing business service.

- [ ] **Step 3: Add Docker and Compose preflight**

Implement `require_linux`, `require_privileges`, `ensure_docker`, `ensure_compose`, and `compose_cmd`. Follow the existing installer's supported Linux distribution and Docker installation pattern when Docker is missing. Verify Docker Engine and Compose v2 before lifecycle commands; library-mode tests must stub these functions.

- [ ] **Step 4: Add safe lifecycle commands and diagnostics**

Implement `validate_compose`, `refresh_and_start`, `show_service_status`, and `show_failure_diagnostics` with this exact sequence:

```text
docker compose config -q
docker compose pull
docker compose up -d
docker compose ps
```

All commands must use the generated `--env-file` and `--file` paths. Diagnostics may show only `ps` and the last 100 lines of `nacos-registrar` logs, with Nacos username, password, URL credentials, and any generated secret redacted. Never run `docker compose down`, `docker system prune`, or commands naming another service.

- [ ] **Step 5: Test lifecycle order and rerun behavior**

Stub `compose_cmd` to record arguments and assert `config -q`, `pull`, and `up -d` occur in order. Stub `check_ready_endpoint` and assert a failed preflight prevents any Compose call. Write existing `.env` values, clear shell variables, call `prepare_env`, and assert values are reused; then set an explicit CLI value and assert it overrides the stored value.

- [ ] **Step 6: Commit the Compose lifecycle**

```bash
git add install-nacos-sidecar.sh tests/test_install_nacos_sidecar.sh
git commit -m "Run the Nacos Sidecar in isolated host-network Compose"
```

Record the host-network and no-business-lifecycle constraints in Lore trailers.

### Task 4: Add registrar lifecycle regression coverage and operator documentation

**Files:**
- Modify: `tests/test_install_nacos_sidecar.sh`
- Create: `tests/test_nacos_sidecar_registrar.py`
- Create: `docs/superpowers/plans/2026-08-30-standalone-nacos-sidecar-operations.md`

- [ ] **Step 1: Add Python registrar lifecycle tests**

Compile the generated `nacos/registrar.py` and test unauthenticated and authenticated fake-Nacos lifecycles using the same HTTP stub approach as `tests/test_nacos_registrar.py`. Assert login, instance registration, heartbeat, token refresh, readiness loss deregistration, and final signal-driven deregistration use only Nacos v1 paths.

- [ ] **Step 2: Add operator documentation**

Document:

```bash
./install-nacos-sidecar.sh --nacos-url http://nacos.example.test:8848/nacos
```

Explain that the default directory is `./mail-nacos-sidecar`, the default service is `mail-cluster`, the existing service must be reachable at `127.0.0.1:5000/health/ready`, and Linux host networking is what makes that address reachable inside the Sidecar. Include authenticated and unauthenticated examples, exact `注册ip:` prompting, start/stop/status commands, and a warning that all existing business containers remain outside this Compose project.

- [ ] **Step 3: Verify historical files are unchanged**

Capture `git hash-object install-node.sh install-node-nacos.sh` before implementation and compare after all changes. The hashes must match. Also assert the new script contains no edits or references that require changing those files.

- [ ] **Step 4: Run complete verification**

Run:

```bash
bash -n install-nacos-sidecar.sh
bash -n install-node.sh
bash -n install-node-nacos.sh
bash tests/test_install_nacos_sidecar.sh
python3 tests/test_nacos_sidecar_registrar.py
bash tests/test_install_node_nacos.sh
bash tests/test_install_node_nacos_interactive.sh
docker compose --env-file ./mail-nacos-sidecar/.env -f ./mail-nacos-sidecar/docker-compose.yml config -q
git diff --check HEAD~4..HEAD
```

Run a sensitive-pattern scan that fails on public IP lookup services, `--nacos-password`, literal passwords in Compose, public Admin-style bindings, or broad Docker cleanup commands. Report live Docker/Nacos startup separately from local rendering and fake-server tests.

- [ ] **Step 5: Commit documentation and final fixes**

```bash
git add install-nacos-sidecar.sh tests/test_install_nacos_sidecar.sh tests/test_nacos_sidecar_registrar.py docs/superpowers/plans/2026-08-30-standalone-nacos-sidecar-operations.md
git commit -m "Document and verify standalone Nacos Sidecar operations"
```

Use Lore trailers for verified local behavior and any environment-dependent live-test gaps.
