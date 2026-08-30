# Nacos 3 Registrar Design

## Goal

Replace the generated registrar's Nacos v1 HTTP lifecycle with the Nacos 3 client Open API so replica nodes can register against the deployed Nacos 3 server without changing the third-party business image.

## Compatibility Decision

The registrar supports Nacos 3 only. It does not probe or fall back to Nacos v1, and it does not add an API-version installer option. A single protocol keeps failures deterministic and matches the current deployment.

`NACOS_SERVER_URL` continues to accept either `http(s)://host:port` or `http(s)://host:port/nacos`. The registrar normalizes both forms to the server origin and uses Nacos 3 paths explicitly.

## Protocol

The generated registrar uses these endpoints:

- Login: `POST /nacos/v3/auth/user/login`
- Register: `POST /nacos/v3/client/ns/instance` with `heartBeat=false`
- Heartbeat: `POST /nacos/v3/client/ns/instance` with `heartBeat=true`
- Deregister: `DELETE /nacos/v3/client/ns/instance`

Register, heartbeat, and deregister send the same instance identity fields: `serviceName`, `namespaceId`, `groupName`, `clusterName`, `ip`, `port`, and `ephemeral`. Registration also sends `weight`, `enabled`, and `healthy` as supported instance attributes.

## Authentication

When Nacos credentials are configured, the registrar posts the username and password to the Nacos 3 login endpoint and reads `accessToken` from the response. Subsequent instance requests send `Authorization: Bearer <token>` rather than putting the token in a query string.

An HTTP 401 or 403 clears the cached token, logs no credential or token value, logs in once more, and retries the failed instance request once. Unauthenticated mode sends no authorization header.

## Response Handling

Nacos 3 instance APIs return a JSON result envelope. HTTP success alone is not sufficient:

- `code=0` is success.
- Heartbeat `code=21003` means the instance is absent; the registrar marks itself unregistered and immediately registers again.
- Any other code raises a sanitized registrar error containing only the numeric Nacos result code.
- Invalid or non-JSON success bodies are treated as protocol errors and retried through the existing bounded exponential backoff.

HTTP errors retain the current sanitized `HTTP <status>` logging. Passwords, access tokens, response bodies, and request authorization headers are never logged.

## Lifecycle

The existing business readiness gate remains unchanged. The registrar registers only after `http://outlook-mail-replica:5000/health/ready` succeeds, heartbeats while the replica remains ready, deregisters when readiness is lost or the process terminates, and registers again after recovery.

The advertised endpoint remains `NACOS_ADVERTISE_IP:OUTLOOK_EMAIL_PORT`. It must be reachable from APISIX; container-internal addresses and container port 5000 are not appropriate when APISIX reaches the node through its host mapping.

## Generated Artifacts And Upgrade

Only the registrar generator and its tests change. The Compose service shape, third-party image, node enrollment identity, persisted `.env`, and installer interaction remain unchanged.

After updating the repository on an existing node, rerunning `install-node-nacos.sh` regenerates `nacos/registrar.py`, reuses the existing enrollment identity and `.env` defaults, and recreates the registrar container with the Nacos 3 implementation.

## Verification

The mock Nacos lifecycle server is changed to the v3 paths and JSON result envelope. Tests cover:

- Authenticated Nacos 3 login and Bearer authorization without secret logging.
- Initial registration retry after an HTTP failure.
- Heartbeat through `POST` with `heartBeat=true`.
- Token refresh after heartbeat HTTP 401.
- Re-registration after heartbeat result code `21003`.
- Deregistration while unhealthy and during shutdown.
- Registration after replica recovery.
- The complete unauthenticated lifecycle.
- Generated registrar syntax, Compose parsing when Docker is available, Bash syntax, LF endings, and sensitive-pattern scans.
