# Nacos 3 Registrar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the generated registrar's Nacos v1 lifecycle with authenticated and unauthenticated Nacos 3 client Open API behavior.

**Architecture:** Keep the installer and Compose boundary unchanged. Update the Python registrar embedded in `install-node-nacos.sh` to use one Nacos 3 instance endpoint for register, heartbeat, and deregister, validate JSON result envelopes, and carry authentication as a Bearer header; update the existing HTTP mock lifecycle suite before production code.

**Tech Stack:** Bash 4+, Python 3 standard library, Docker Compose v2, Nacos 3 HTTP Open API, `unittest`

---

### Task 1: Lock the Nacos 3 HTTP contract with failing lifecycle tests

**Files:**
- Modify: `tests/test_nacos_registrar.py`
- Modify: `tests/test_install_node_nacos.sh`
- Test: `install-node-nacos.sh`

- [ ] **Step 1: Change the mock server to Nacos 3 response semantics**

Change `Recorder` so each request stores `(method, path, params, authorization)` and add parameter-aware counting:

```python
def add(self, method, path, params, authorization=''):
    with self.condition:
        self.requests.append((method, path, params, authorization))
        self.condition.notify_all()

def count_matching(self, method, path, expected=None):
    expected = expected or {}
    with self.condition:
        return sum(
            1
            for request_method, request_path, params, _authorization
            in self.requests
            if request_method == method
            and request_path == path
            and all(params.get(key) == [value] for key, value in expected.items())
        )

def wait_for_matching(self, method, path, expected=None, count=1, timeout=8):
    deadline = time.monotonic() + timeout
    with self.condition:
        while self.count_matching(method, path, expected) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            self.condition.wait(remaining)
    return True
```

Make `NacosHandler._record_request` capture `Authorization`. Return JSON envelopes through:

```python
def _send_result(self, code=0, message='success', data='ok'):
    self._send(
        200,
        json.dumps({'code': code, 'message': message, 'data': data}).encode(),
        'application/json',
    )
```

Handle `POST /nacos/v3/auth/user/login` by returning `accessToken`. Handle `POST /nacos/v3/client/ns/instance` as registration when `heartBeat=false` and heartbeat when `heartBeat=true`. Return HTTP 401 for the requested token-refresh case and JSON `code=21003` for the missing-instance case. Handle `DELETE` on the same instance path. Authenticated instance calls must require `Authorization: Bearer test-token-*` and must not accept an `accessToken` query or form field.

- [ ] **Step 2: Rewrite lifecycle assertions around the shared v3 endpoint**

Use these constants in both lifecycle tests:

```python
login_path = '/nacos/v3/auth/user/login'
instance_path = '/nacos/v3/client/ns/instance'
register_params = {'heartBeat': 'false'}
heartbeat_params = {'heartBeat': 'true'}
```

The authenticated test must observe two registration attempts after one HTTP 500, refresh authentication after a heartbeat HTTP 401, re-register after a heartbeat `code=21003`, deregister when readiness is false, register after recovery, and deregister on process termination. Assert that register, heartbeat, and deregister carry identical identity values, heartbeat is a `POST`, authenticated calls use a Bearer header, and no request contains `accessToken` in its parameters.

The unauthenticated test must observe register, heartbeat, and shutdown deregistration on the v3 endpoint and zero login calls.

- [ ] **Step 3: Update generated-artifact contract assertions**

Replace the v1 string assertions in `tests/test_install_node_nacos.sh` with:

```bash
assert_contains "$REGISTRAR_FILE" '/nacos/v3/auth/user/login'
assert_contains "$REGISTRAR_FILE" '/nacos/v3/client/ns/instance'
assert_contains "$REGISTRAR_FILE" 'Authorization'
assert_not_contains "$REGISTRAR_FILE" '/nacos/v1/'
assert_not_contains "$REGISTRAR_FILE" '"accessToken"] ='
```

- [ ] **Step 4: Run tests and verify RED**

Run: `bash tests/test_install_node_nacos.sh`

Expected: FAIL because the generated registrar still contains v1 paths and sends heartbeat with `PUT /nacos/v1/ns/instance/beat`.

- [ ] **Step 5: Commit the verified failing tests**

```bash
git add tests/test_nacos_registrar.py tests/test_install_node_nacos.sh
git commit -m "Define the deployed Nacos 3 registrar contract" -m "Lifecycle coverage now describes the protocol exposed by the deployed registry before generated registrar behavior changes.\n\nConstraint: Authentication tokens must not be placed in URLs or form parameters\nConfidence: high\nScope-risk: narrow\nTested: Registrar contract test fails on legacy v1 generated paths\nNot-tested: Production implementation follows in the next commit"
```

### Task 2: Implement the Nacos 3 registrar lifecycle

**Files:**
- Modify: `install-node-nacos.sh:590`
- Test: `tests/test_nacos_registrar.py`
- Test: `tests/test_install_node_nacos.sh`

- [ ] **Step 1: Add sanitized Nacos result parsing**

Add this generated Python error and decoder before `NacosRegistrar`:

```python
class NacosResultError(RuntimeError):
    def __init__(self, code):
        self.code = code
        super().__init__(f"Nacos API result code {code}")


def decode_result_code(body):
    try:
        payload = json.loads(body.decode("utf-8"))
        return int(payload["code"])
    except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError, ValueError):
        raise RuntimeError("Nacos response was not a valid result envelope") from None
```

Result messages and response bodies are intentionally not included in exceptions or logs.

- [ ] **Step 2: Send credentials through the Nacos 3 login and Bearer header**

Change `_perform` to accept `access_token=None` and add this header when present:

```python
if access_token:
    headers["Authorization"] = f"Bearer {access_token}"
```

Change `_login` to call `POST /nacos/v3/auth/user/login`. Change `_request` to pass the cached token to `_perform`; remove the mutation that adds `accessToken` to request parameters. Keep the existing single 401/403 refresh attempt.

- [ ] **Step 3: Replace v1 instance operations with the shared v3 endpoint**

Use a class constant:

```python
INSTANCE_PATH = "/nacos/v3/client/ns/instance"
```

Add `heartBeat=false` to registration, call the instance path with `POST`, decode the result, and require `code=0`. Heartbeat sends the same identity parameters with `heartBeat=true` using `POST`; `code=21003` marks the registrar unregistered and invokes `register`, while any other nonzero code raises `NacosResultError`. Deregistration sends the same identity through `DELETE` and requires `code=0`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
bash -n install-node-nacos.sh
bash tests/test_install_node_nacos.sh
```

Expected: Bash syntax exits 0, both authenticated and unauthenticated Nacos 3 lifecycle tests pass, and the shell suite prints `PASS: install-node-nacos contract and lifecycle`.

- [ ] **Step 5: Commit the implementation**

```bash
git add install-node-nacos.sh
git commit -m "Register replica nodes through the Nacos 3 client API" -m "The generated sidecar now uses the deployed Nacos 3 login and instance lifecycle, including POST heartbeats, Bearer authentication, and missing-instance recovery.\n\nConstraint: Keep the third-party business image and Compose topology unchanged\nRejected: Legacy v1 fallback | masks deployment protocol errors\nConfidence: high\nScope-risk: moderate\nDirective: Keep register and heartbeat on the shared v3 client endpoint\nTested: Bash syntax and authenticated/unauthenticated mock Nacos 3 lifecycle\nNot-tested: Live Nacos 3 deployment"
```

### Task 3: Verify integration and deployment safety

**Files:**
- Test: `install-node.sh`
- Test: `install-node-nacos.sh`
- Test: `tests/test_install_node_nacos.sh`
- Test: `tests/test_install_node_nacos_interactive.sh`

- [ ] **Step 1: Run all functional tests**

Run:

```bash
bash -n install-node.sh
bash -n install-node-nacos.sh
bash tests/test_install_node_nacos.sh
bash tests/test_install_node_nacos_interactive.sh
```

Expected: both syntax checks exit 0, the nested registrar suite reports two passing tests, and both shell suites print PASS.

- [ ] **Step 2: Run safety and formatting checks**

Run:

```bash
git diff --check HEAD~2..HEAD
if grep -Il $'\r' install-node-nacos.sh tests/test_install_node_nacos.sh tests/test_install_node_nacos_interactive.sh tests/test_nacos_registrar.py; then exit 1; fi
if rg -n '(api\.ipify\.org|ifconfig\.me|--nacos-password|APISIX_ADMIN_KEY)' install-node-nacos.sh; then exit 1; fi
if rg -n '/nacos/v1/' install-node-nacos.sh tests/test_nacos_registrar.py; then exit 1; fi
```

Expected: no whitespace errors, CRLF, prohibited secret/public-IP behavior, or v1 runtime/test path remains.

- [ ] **Step 3: Review the final diff against the specification**

Run `git diff ab07afb..HEAD -- install-node-nacos.sh tests` and `git status --short --branch`. Confirm no Compose service, business image, enrollment, interactive input, or persisted environment behavior changed.

- [ ] **Step 4: Merge, verify on master, and push**

Fast-forward `master` to `feature/nacos-v3-registrar`, rerun Task 3 Steps 1 and 2 from the main worktree, then push with `git push origin master` only if the remote has not diverged. Remove the clean worktree and merged feature branch after the remote branch points at the verified commit.
