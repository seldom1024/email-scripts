# Standalone Nacos Sidecar Operations

Use this installer when the business container is already deployed and reachable on the host, but it was not originally configured with the Nacos registrar.

## Prerequisites

The existing service must respond successfully at:

```text
http://127.0.0.1:5000/health/ready
```

The installer supports Linux Docker Engine with Docker Compose v2. The Sidecar uses `network_mode: host`; on Linux this makes `127.0.0.1:5000` inside the Sidecar refer to the host-published business port. The Sidecar does not need the business container name or Docker network name.

## Interactive Installation

Run from the directory where the Sidecar project should be created:

```bash
./install-nacos-sidecar.sh --nacos-url http://nacos.example.test:8848/nacos
```

The default project directory is `./mail-nacos-sidecar`. When no `--advertise-ip` is supplied and `.env` has no saved value, the installer prompts:

```text
注册ip:
```

Enter the address that Nacos clients and APISIX can use to reach this node. The installer does not discover a public address through an external service.

Defaults:

```text
Nacos service: mail-cluster
Namespace:     public
Group:         DEFAULT_GROUP
Cluster:       DEFAULT
Port:          5000
Ready URL:     http://127.0.0.1:5000/health/ready
```

At the Nacos username prompt, press Enter for unauthenticated mode. If a username is entered, the password is read without echo. There is no `--nacos-password` option. For unattended authentication, provide `NACOS_USERNAME` and `NACOS_PASSWORD` in the process environment.

## Unattended Installation

```bash
NACOS_PASSWORD='nacos-password' ./install-nacos-sidecar.sh \
  --project-dir ./mail-nacos-sidecar \
  --nacos-url http://nacos.example.test:8848/nacos \
  --nacos-service mail-cluster \
  --advertise-ip 198.51.100.20 \
  --advertise-port 5000 \
  --ready-url http://127.0.0.1:5000/health/ready \
  --nacos-namespace public \
  --nacos-group DEFAULT_GROUP \
  --nacos-cluster DEFAULT \
  --nacos-username nacos-user
```

For unauthenticated operation, set `NACOS_USERNAME=` and `NACOS_PASSWORD=` in the environment or complete the interactive username prompt with Enter.

## Generated Files

The installer creates only these files under `./mail-nacos-sidecar` (or `--project-dir`):

- `.env`, mode `600`, containing the selected registration values and credentials;
- `docker-compose.yml`, mode `600`, defining only `nacos-registrar`;
- `nacos/registrar.py`, mode `600`, containing the Nacos v1-compatible registrar;
- `data/`, reserved for this Sidecar project.

The Compose service has no `ports`, no business image, no `depends_on`, and no business container lifecycle. It cannot restart or stop the existing business service.

## Lifecycle Commands

Run commands from the project directory:

```bash
docker compose --env-file .env -f docker-compose.yml ps
docker compose --env-file .env -f docker-compose.yml logs --tail 100 nacos-registrar
docker compose --env-file .env -f docker-compose.yml restart nacos-registrar
docker compose --env-file .env -f docker-compose.yml stop nacos-registrar
```

Stopping the Sidecar causes the registrar to deregister its instance during normal termination. Stopping the Sidecar does not stop the business container.

## Nacos Registration

The registrar uses the Nacos v1-compatible endpoints required by APISIX discovery:

```text
/nacos/v1/auth/users/login
/nacos/v1/ns/instance
/nacos/v1/ns/instance/beat
```

When the readiness endpoint is unavailable, the registrar removes the instance from Nacos and waits for recovery. It re-registers after the endpoint becomes healthy again.

All nodes that should be discovered as one APISIX pool must use the same service name, normally `mail-cluster`, namespace, and group. This installer does not rename existing registrations or migrate Nacos data.

## Troubleshooting

Check the host readiness endpoint first:

```bash
curl -fsS http://127.0.0.1:5000/health/ready
```

Then inspect the Sidecar status and last 100 log lines. The installer validates Compose before starting and redacts configured credentials from failure diagnostics. Live Nacos connectivity, firewall rules, namespace/group correctness, and APISIX Upstream configuration must be checked separately.
