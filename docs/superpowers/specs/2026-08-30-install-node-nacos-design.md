# Nacos Replica Installer Design

## Goal

Add a self-contained `install-node-nacos.sh` installer that deploys the existing third-party replica image unchanged and registers the reachable replica endpoint with Nacos through a separate sidecar container.

## Constraints

- Do not modify or rebuild `seldomzq/email`.
- Do not hardcode or automatically publish a public IP.
- Preserve the enrollment, Docker installation, port selection, and readiness behavior of `install-node.sh`.
- Add no host dependencies beyond those already installed by the installer.
- Keep Nacos credentials out of command-line arguments and store generated configuration in the existing mode-600 `.env` file.

## Interface

The new installer retains all existing `install-node.sh` arguments and adds:

- `--nacos-url URL`
- `--nacos-service NAME`
- `--advertise-ip IP`
- `--nacos-namespace ID` (default `public`)
- `--nacos-group NAME` (default `DEFAULT_GROUP`)
- `--nacos-cluster NAME` (default `DEFAULT`)

Required values may be supplied by command-line arguments or completed interactively. Secrets are not accepted as CLI arguments.

## Interactive Resolution

After parsing arguments and resolving the installation directory, the installer fills missing values before making host changes:

1. Command-line values take precedence.
2. Existing `.env` values provide defaults for the master URL, Nacos URL, Nacos service name, and advertised IP.
3. Values still missing are read from standard input in this order: master URL, node ID, master fingerprint, Nacos URL, Nacos service name, and advertised IP.

Prompts with an existing `.env` value display that default. Pressing Enter reuses it; entering a new value replaces it. Invalid interactive input reports the validation error and prompts again. End-of-file before a required value produces a clear error instead of continuing or waiting indefinitely.

Nacos credentials use this precedence:

1. A complete `NACOS_USERNAME` and `NACOS_PASSWORD` pair from the process environment.
2. A complete pair already stored in `.env`.
3. Interactive input when neither source contains credentials.

The username prompt explains that Enter selects unauthenticated Nacos. A non-empty username triggers a hidden password prompt; an empty password is rejected and requested again. Partial environment or `.env` credential pairs are rejected. Interactive results are persisted in the mode-600 `.env` file, including empty username and password values for unauthenticated mode.

## Deployment

The generated Compose project contains two services:

1. `outlook-mail-replica` runs the unchanged email image and exposes the selected host port to container port 5000.
2. `nacos-registrar` runs `python:3.12-alpine`, mounts a generated standard-library-only registrar script read-only, and shares the default Compose network with the replica.

The registrar publishes `NACOS_ADVERTISE_IP:OUTLOOK_EMAIL_PORT`, not its own container address. It probes `http://outlook-mail-replica:5000/health/ready` inside the Compose network.

## Registrar Lifecycle

The registrar validates configuration on startup, optionally authenticates through the Nacos v1 authentication endpoint, and then runs this state machine:

1. Wait for the replica readiness endpoint.
2. Register an enabled, healthy, ephemeral Nacos instance.
3. Send periodic heartbeats while the replica remains ready.
4. Reauthenticate and retry with bounded exponential backoff after Nacos failures.
5. Deregister when the replica becomes unhealthy or the registrar receives SIGTERM/SIGINT.
6. Register again after the replica recovers.

Registrar failure does not terminate the business container. Docker restarts the registrar independently.

## APISIX Contract

APISIX configuration is intentionally outside this installer. APISIX must enable Nacos discovery and use an Upstream with matching `service_name`, `namespace_id`, and `group_name`. No APISIX Admin key or address is stored in this repository.

## Error Handling

- Invalid URL, IPv4 address, port, or service identifiers fail before deployment.
- Missing one half of the Nacos username/password pair fails before deployment.
- Invalid interactive values are requested again; end-of-file while a required prompt is outstanding fails clearly.
- Business startup failures retain existing diagnostics.
- Nacos outages are logged by the sidecar and retried without reporting a false successful registration.
- HTTP errors log only sanitized status or exception types and never expose credentials or access tokens.

## Verification

- Bash syntax checks for both node installers.
- Library-mode tests for Nacos argument validation and generated artifacts.
- Shell tests for command-line precedence, `.env` defaults, complete interactive input, unauthenticated Enter handling, hidden password input, validation retry, and end-of-file failure.
- Registrar integration test with local mock business and Nacos HTTP servers covering register, heartbeat, and deregister.
- Static scan confirming no public IP, Admin key, or APISIX endpoint is hardcoded.
