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

- `--nacos-url URL` (required)
- `--nacos-service NAME` (required)
- `--advertise-ip IP` (required)
- `--nacos-namespace ID` (default `public`)
- `--nacos-group NAME` (default `DEFAULT_GROUP`)
- `--nacos-cluster NAME` (default `DEFAULT`)

Optional `NACOS_USERNAME` and `NACOS_PASSWORD` values are read from the process environment or reused from `.env`. Both must be provided together. Secrets are not accepted as CLI arguments.

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
- Business startup failures retain existing diagnostics.
- Nacos outages are logged by the sidecar and retried without reporting a false successful registration.
- HTTP errors include bounded response text without exposing credentials.

## Verification

- Bash syntax checks for both node installers.
- Library-mode tests for Nacos argument validation and generated artifacts.
- Registrar integration test with local mock business and Nacos HTTP servers covering register, heartbeat, and deregister.
- Static scan confirming no public IP, Admin key, or APISIX endpoint is hardcoded.
