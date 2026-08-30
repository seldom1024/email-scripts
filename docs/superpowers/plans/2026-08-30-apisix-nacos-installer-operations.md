# APISIX Nacos Installer Operations

This document covers the standalone `install-apisix-nacos.sh` workflow after the installer has been implemented. It focuses on how to run it, what it generates, and how to finish APISIX wiring against Nacos.

## What The Installer Does

`install-apisix-nacos.sh` deploys APISIX with Docker Compose and writes a local project directory containing:

- `config.yaml`
- `docker-compose.yml`
- `.env`
- `dashboard-conf.yaml` when Dashboard is enabled
- `data/etcd/` for etcd persistence

The project directory defaults to the current working directory unless `--project-dir` is set.

The generated config files are written with mode `600`.

The installer does not create business routes or Upstreams. It only configures APISIX to use Nacos discovery.

## Supported Inputs

The script accepts these flags:

- `--project-dir PATH`
- `--nacos-url URL`
- `--nacos-service NAME`
- `--nacos-namespace ID`
- `--nacos-group NAME`
- `--nacos-username USER`
- `--http-port PORT`
- `--https-port PORT`
- `--admin-port PORT`
- `--admin-bind IP`
- `--admin-key KEY`
- `--dashboard`
- `--dashboard-port PORT`
- `--dashboard-username USER`
- `--dashboard-password PASS`
- `-h`, `--help`

The current validator only accepts `127.0.0.1` for `--admin-bind`.

## Interactive Use

If a required value is not passed on the command line and is not already present in `.env`, the installer prompts for it.

Typical interactive start:

```bash
./install-apisix-nacos.sh --project-dir /opt/apisix-nacos
```

The script prompts for:

- Nacos server URL
- Nacos service name
- Nacos namespace
- Nacos group
- Nacos username
- Nacos password when a username is entered
- Whether to enable Dashboard
- Dashboard password when Dashboard is enabled

Interactive details:

- Pressing Enter at the Nacos username prompt means no authentication.
- When a Nacos username is provided, the password is read silently.
- When Dashboard is enabled, the username defaults to `admin` unless provided.
- The Dashboard password has no default and must be entered.
- Existing `.env` values are reused as defaults on reruns.

## Unattended Use

For unattended installs, pass every value explicitly:

```bash
./install-apisix-nacos.sh \
  --project-dir /opt/apisix-nacos \
  --nacos-url http://nacos.example.test:8848/nacos \
  --nacos-service outlook-email \
  --nacos-namespace public \
  --nacos-group DEFAULT_GROUP \
  --nacos-username nacos-user \
  --http-port 9080 \
  --https-port 9443 \
  --admin-port 9180 \
  --admin-bind 127.0.0.1 \
  --admin-key 'admin-key' \
  --dashboard \
  --dashboard-port 9000 \
  --dashboard-username admin \
  --dashboard-password 'dashboard-password'
```

For an unattended authenticated install, provide `NACOS_PASSWORD` in the process environment instead of a command-line flag so it does not appear in shell history or the process list:

```bash
NACOS_PASSWORD='nacos-password' ./install-apisix-nacos.sh --nacos-username nacos-user --nacos-url http://nacos.example.test:8848/nacos
```

Behavior to keep in mind:

- `--nacos-url` must be `http://` or `https://` with no query string or fragment.
- A trailing `/nacos` is accepted and normalized.
- `--nacos-service` defaults to `outlook-email`.
- `--nacos-namespace` defaults to `public`.
- `--nacos-group` defaults to `DEFAULT_GROUP`.
- `--http-port` defaults to `9080`.
- `--https-port` defaults to `9443`.
- `--admin-port` defaults to `9180`.
- `--dashboard-port` defaults to `9000`.
- `--admin-key` is generated if omitted and stored in `.env`.
- Leaving `--nacos-username` and `--nacos-password` empty disables Nacos authentication.

## Generated APISIX Configuration

`config.yaml` is rendered in APISIX traditional mode with etcd and native Nacos discovery. The important discovery block is:

```yaml
discovery:
  nacos:
    host:
      - "http://[user:password@]nacos-host:8848"
    prefix: "/nacos/v1/"
    fetch_interval: 30
```

The generated APISIX configuration restricts Admin API requests to localhost and the private Docker network, writes the Admin key into `config.yaml`, and mounts the file read-only in Compose. The container listens on its network interface so Docker can forward the host binding correctly; the host-side Admin port is still published only on `127.0.0.1`.

## Generated Dashboard Configuration

When Dashboard is enabled, the installer generates `dashboard-conf.yaml` and mounts it into the Dashboard container.

The generated Dashboard service listens on `0.0.0.0` inside the container and exposes the host port you selected, usually `127.0.0.1:9000`.

When Dashboard is disabled:

- `dashboard-conf.yaml` is removed if it exists
- the Compose file does not include the Dashboard service
- no Dashboard port is published

## Generated Compose Layout

The Compose project contains:

- `etcd`
- `apisix`
- `apisix-dashboard` only when `--dashboard` is enabled

APISIX publishes:

- HTTP `9080`
- HTTPS `9443`
- Admin API `127.0.0.1:9180`

The etcd data directory is bound to `./data/etcd`.

## APISIX Upstream Shape

Create the Upstream separately in APISIX Dashboard or through the Admin API.

Use this service identity so APISIX can discover every node in the same Nacos service:

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

All business nodes that should be discovered together must register under the same Nacos service name. This installer does not create or rename those registrations for you.

## Scope Boundary

This installer does not migrate Nacos data.

That means it does not:

- move instances between Nacos clusters
- convert older service records into APISIX resources
- rewrite existing business registrations
- change service naming conventions on your behalf

If your current Nacos setup needs migration or cleanup, do that outside this installer first, then point APISIX discovery at the final service name.

## Operational Notes

- Generated files are written with restrictive permissions.
- The installer only starts the services in its own Compose project.
- It does not remove unrelated containers.
- It does not create routes automatically, so APISIX will not route traffic until you add an Upstream and route manually.
