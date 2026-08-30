# Standalone Nacos Sidecar Installer Design

## Goal

Add a new `install-nacos-sidecar.sh` script for nodes where the business service is already deployed but the Nacos registrar Sidecar was never installed. The new installer deploys only the registrar and must not modify, recreate, restart, or stop the existing business container.

The existing `install-node.sh` and `install-node-nacos.sh` files and their behavior remain unchanged.

## Existing Service Contract

The existing business service is already reachable from the Linux host at:

```text
http://127.0.0.1:5000/health/ready
```

The Sidecar uses Docker host networking:

```yaml
network_mode: host
```

On Linux, host networking lets the Sidecar share the host network namespace. Therefore, `127.0.0.1:5000` inside the Sidecar reaches the existing service's host-published port. No Docker network lookup or business container name is required.

The installer rejects non-Linux systems because Docker Desktop host networking and platform-specific localhost behavior are outside this contract.

## Independent Deployment

The installer creates a dedicated project directory, defaulting to:

```text
/opt/mail-nacos-sidecar
```

It generates only:

- `.env`, mode `600`;
- `docker-compose.yml` containing one `nacos-registrar` service;
- `nacos/registrar.py`, mode `600`.

The Compose project has no business service definition, no published ports, and no dependency on an existing Compose project. Its lifecycle commands apply only to the generated Sidecar project.

## Defaults And Inputs

Defaults:

```text
Nacos service name: mail-cluster
Namespace:          public
Group:              DEFAULT_GROUP
Cluster:            DEFAULT
Registration port:  5000
Readiness URL:       http://127.0.0.1:5000/health/ready
```

The installer supports these non-secret CLI options:

```text
--project-dir
--nacos-url
--nacos-service
--advertise-ip
--advertise-port
--ready-url
--nacos-namespace
--nacos-group
--nacos-cluster
--nacos-username
```

Missing Nacos URL and registration IP are requested interactively. The service name and other values present their defaults for confirmation. The registration IP must be an explicit usable IPv4 address; the installer never calls a public IP-detection service.

For Nacos authentication, pressing Enter at the username prompt selects unauthenticated mode. When a username is entered, the password is read without echo. For unattended authenticated installation, `NACOS_USERNAME` and `NACOS_PASSWORD` may be provided together in the process environment. There is no password command-line option.

Existing `.env` values are reused on reruns unless a CLI option explicitly overrides them.

## Registrar Lifecycle

The generated registrar preserves the proven Nacos 2.x-compatible behavior currently used by `install-node-nacos.sh`:

1. Wait until the readiness URL returns a successful response.
2. Authenticate through the Nacos v1 login endpoint when credentials are configured.
3. Register the configured IPv4 address and port as an ephemeral healthy instance.
4. Send periodic heartbeats and retry with bounded backoff.
5. Refresh expired authentication when required.
6. Deregister the instance when the Sidecar receives a normal termination signal.

The registrar uses the Nacos v1-compatible endpoints required by APISIX discovery. It does not use Nacos v3-only client endpoints.

If the business health endpoint becomes unavailable, the registrar stops advertising a healthy instance and continues checking until the service recovers. It does not restart or otherwise manage the business service.

## Installation And Startup Flow

The installer performs these steps:

1. Validate all inputs and credential pairs.
2. Verify the host readiness URL is reachable before starting the Sidecar.
3. Verify Linux, privileges, Docker Engine, and Docker Compose v2; install Docker using the repository's existing supported-distribution pattern when necessary.
4. Atomically write the dedicated `.env`, Compose file, and registrar.
5. Run `docker compose config -q`.
6. Pull the registrar image and run `docker compose up -d` for this project only.
7. Show Sidecar status and bounded diagnostics without printing credentials.

The installer never runs broad Docker cleanup commands and never includes or names the existing business container in lifecycle commands.

## Security And Failure Handling

- Secret-bearing files use mode `600`.
- Passwords are never accepted through CLI arguments or printed in logs.
- Nacos URLs, credentials, and registration data are validated before deployment files are replaced.
- Diagnostics are limited to Sidecar status and the last 100 Sidecar log lines, with configured credentials redacted.
- A failed readiness preflight stops installation without changing the existing business container.
- Reruns preserve the Sidecar `.env` and do not delete registration data or unrelated files.

## Testing

Tests run the installer in library mode so they do not start Docker or affect the deployed service. Coverage includes:

- default service name `mail-cluster` and default readiness URL;
- input, IPv4, port, URL, identifier, and credential validation;
- host-network Compose rendering with exactly one Sidecar service;
- absence of business-container definitions and published ports;
- Nacos v1 registration, heartbeat, authentication, and deregistration paths;
- mode `600` for `.env` and registrar files;
- rerun value preservation and explicit override behavior;
- Compose lifecycle command order through stubs;
- prohibited public IP lookup and password CLI patterns;
- checks proving the two historical node installer files are unchanged.

Live verification against the already deployed service and its Nacos server remains environment-dependent and is reported separately.
