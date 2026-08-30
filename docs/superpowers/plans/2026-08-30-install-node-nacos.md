# Nacos Replica Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained replica installer that deploys the unchanged email image with a Nacos registration sidecar.

**Architecture:** Fork the existing self-contained node installer so its Docker, enrollment, configuration, and readiness behavior remain available from one downloadable script. Add an embedded Python standard-library registrar that is materialized into the install directory and run by a separate `python:3.12-alpine` Compose service.

**Tech Stack:** Bash 4+, Docker Compose v2, Python 3 standard library, Nacos v1 HTTP naming API, `unittest`.

---

### Task 1: Lock the installer contract with tests

**Files:**
- Create: `.gitattributes`
- Create: `tests/test_install_node_nacos.sh`
- Create: `tests/test_nacos_registrar.py`

- [x] **Step 1: Require LF shell and Python files**

```gitattributes
*.sh text eol=lf
*.py text eol=lf
```

- [x] **Step 2: Write the failing shell contract test**

The test must source the installer with `INSTALLER_LIB_ONLY=1`, generate artifacts in a temporary directory, and assert:

```bash
assert_contains "$COMPOSE_FILE" 'nacos-registrar:'
assert_contains "$COMPOSE_FILE" 'python:3.12-alpine'
assert_contains "$COMPOSE_FILE" 'NACOS_ADVERTISE_IP=${NACOS_ADVERTISE_IP}'
assert_contains "$REGISTRAR_FILE" 'class NacosRegistrar'
assert_not_contains "$SCRIPT" 'api.ipify.org'
```

It must also run invalid IPv4, URL, identifier, and partial-credential cases in subshells and require nonzero status.

- [x] **Step 3: Write the failing registrar lifecycle test**

Use two local `ThreadingHTTPServer` instances: one returns ready status and the other records Nacos requests. Run the generated registrar as a subprocess with one-second intervals, wait for `POST /nacos/v1/ns/instance` and `PUT /nacos/v1/ns/instance/beat`, terminate it, then require `DELETE /nacos/v1/ns/instance`.

- [x] **Step 4: Run tests and verify red state**

Run:

```bash
bash tests/test_install_node_nacos.sh
```

Expected: failure because `install-node-nacos.sh` does not exist.

### Task 2: Create the Nacos-aware installer

**Files:**
- Create: `install-node-nacos.sh`
- Test: `tests/test_install_node_nacos.sh`

- [x] **Step 1: Preserve the existing installer foundation**

Copy the current `install-node.sh` behavior into the new self-contained file, retaining `set -Eeuo pipefail`, Docker installation, replica enrollment, port selection, `.env` persistence, diagnostics, and `INSTALLER_LIB_ONLY`.

- [x] **Step 2: Add Nacos configuration and validation**

Define these required values and validators:

```bash
NACOS_SERVER_URL=''
NACOS_SERVICE_NAME=''
NACOS_ADVERTISE_IP=''
NACOS_NAMESPACE_ID='public'
NACOS_GROUP_NAME='DEFAULT_GROUP'
NACOS_CLUSTER_NAME='DEFAULT'

validate_nacos_url
validate_ipv4
validate_nacos_identifier
validate_nacos_credentials
```

`validate_nacos_url` accepts only `http` or `https` URLs with an authority and
without a query or fragment. `validate_ipv4` accepts four decimal octets in the
range 0-255 and rejects loopback, unspecified, multicast, and broadcast
addresses. `validate_nacos_identifier` accepts non-empty service, namespace,
group, and cluster values made from letters, digits, dot, dash, underscore, or
colon. `validate_nacos_credentials` requires username and password together and
rejects newline characters before either value is written to `.env`.

Parse the six documented Nacos CLI options and require URL, service, and advertised IP before host mutation begins.

- [x] **Step 3: Persist sidecar configuration**

Extend environment preparation to upsert:

```text
NACOS_SERVER_URL
NACOS_SERVICE_NAME
NACOS_ADVERTISE_IP
NACOS_NAMESPACE_ID
NACOS_GROUP_NAME
NACOS_CLUSTER_NAME
NACOS_USERNAME
NACOS_PASSWORD
```

Reuse existing credentials from `.env`; accept new credentials only through process environment; require username and password together.

- [x] **Step 4: Generate Compose and registrar artifacts**

Add `REGISTRAR_FILE="$PROJECT_DIR/nacos/registrar.py"`. Generate it atomically with mode 600. Extend Compose with `nacos-registrar`, read-only script mount, Nacos variables, internal readiness URL, bounded intervals, `restart: unless-stopped`, and a stop grace period.

- [x] **Step 5: Start and diagnose both services**

Pull both images, start the Compose project, retain the existing business readiness gate, and show logs for both containers after failures. The summary must report Nacos service identity and advertised endpoint without printing credentials.

- [x] **Step 6: Run shell tests and verify green state**

Run:

```bash
bash tests/test_install_node_nacos.sh
```

Expected: all shell contract checks pass and the Python lifecycle test is invoked.

### Task 3: Implement the registrar lifecycle

**Files:**
- Modify: `install-node-nacos.sh`
- Test: `tests/test_nacos_registrar.py`

- [x] **Step 1: Implement configuration and URL building**

The generated registrar must use `os.environ`, `ipaddress.ip_address`, and `urllib.parse`. Normalize either `http://host:8848` or `http://host:8848/nacos` to a single `/nacos/v1` API base.

- [x] **Step 2: Implement authenticated HTTP requests**

Use `urllib.request` with bounded timeouts. If credentials exist, obtain `accessToken` from `POST /nacos/v1/auth/users/login`; refresh once after HTTP 401 or 403. Never include passwords or tokens in logs.

- [x] **Step 3: Implement register, heartbeat, and deregister**

Register an ephemeral healthy instance through `POST /ns/instance`, heartbeat through `PUT /ns/instance/beat`, and deregister through `DELETE /ns/instance`. Use identical service, namespace, group, cluster, IP, and port values for all operations.

- [x] **Step 4: Implement health-driven state transitions**

Probe the replica readiness URL. Register only while ready, deregister after readiness is lost, recover registration after readiness returns, and retry Nacos failures with exponential backoff capped at 30 seconds.

- [x] **Step 5: Implement signal cleanup**

SIGTERM and SIGINT set a stop event. The `finally` block attempts bounded deregistration and exits without hanging Compose shutdown.

- [x] **Step 6: Run lifecycle integration test**

Run:

```bash
python tests/test_nacos_registrar.py
```

Expected: register, heartbeat, and deregister assertions pass.

### Task 4: Verify and document completion

**Files:**
- Modify: `docs/superpowers/plans/2026-08-30-install-node-nacos.md`

- [x] **Step 1: Run syntax checks**

```bash
bash -n install-node.sh
bash -n install-node-nacos.sh
python -m py_compile tests/test_nacos_registrar.py
```

- [x] **Step 2: Run the complete test suite**

```bash
bash tests/test_install_node_nacos.sh
```

- [x] **Step 3: Scan for leaked configuration**

```bash
rg -n -F -e 'APISIX_ADMIN_URL' -e 'ADMIN_KEY="123"' .
```

Expected: no matches outside historical design discussion; executable/configuration files contain none.

- [x] **Step 4: Review the diff**

```bash
git diff --check
git status --short
git diff --stat HEAD
```

- [x] **Step 5: Commit implementation with Lore trailers**

Stage only `.gitattributes`, `install-node-nacos.sh`, tests, and the implementation plan. Record test evidence and the intentional sidecar boundary in the commit message.
