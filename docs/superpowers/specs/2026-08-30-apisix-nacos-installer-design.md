# APISIX Nacos Installer Design

## Goal

Add a standalone `install-apisix-nacos.sh` installer that deploys Apache APISIX with Docker Compose, configures its built-in Nacos discovery client for the Nacos 2.x-compatible HTTP API, and optionally starts an APISIX Dashboard. This installer is independent from the existing node installers and must not alter their files or behavior.

## Scope

The installer creates a self-contained deployment directory containing:

- `.env` with mode `600` permissions;
- `config.yaml` with APISIX and Nacos discovery configuration;
- `docker-compose.yml` containing APISIX and etcd, plus an optional Dashboard service;
- a local data directory for etcd persistence.

It does not create business routes or Upstreams. Operators create an Upstream and route separately, using the shared Nacos service name `outlook-email`.

## Runtime Topology

The default Compose project contains:

1. `etcd`, using the official etcd image and a persistent local data volume;
2. `apisix`, using the official APISIX image, mounting the generated `config.yaml`, and exposing HTTP `9080`, HTTPS `9443`, and Admin API `9180`;
3. `apisix-dashboard`, only when requested, using the official Dashboard image and exposing port `9000`.

The Admin API binds to localhost by default. Dashboard communicates with the Admin API over the private Compose network. Public proxy ports remain available for traffic. Host port values are configurable so an existing service can avoid conflicts.

## Interactive Inputs

The script accepts CLI options for unattended execution and prompts for missing values. The required configuration is:

- Nacos server URL, accepting `http(s)://host[:port]` with an optional `/nacos` suffix;
- shared Nacos service name, default `outlook-email`;
- Nacos namespace, default `public`;
- Nacos group, default `DEFAULT_GROUP`;
- optional Nacos username and hidden password; pressing Enter for the username disables Nacos authentication;
- APISIX HTTP port, default `9080`;
- APISIX HTTPS port, default `9443`;
- APISIX Admin API port, default `9180` and bound to `127.0.0.1`;
- whether to install Dashboard;
- Dashboard username and hidden password when enabled, with no default password;
- Dashboard port, default `9000` when enabled;
- APISIX Admin Key, generated securely when omitted and never printed in full.

The installer also supports `--project-dir` and `--help`. Existing `.env` values provide defaults on reruns. Credentials and keys are never accepted as positional secrets or written to logs.

## APISIX Nacos Configuration

The generated APISIX configuration uses the native discovery provider:

```yaml
discovery:
  nacos:
    host:
      - "http://[optional-user:password@]nacos-host:8848"
    prefix: "/nacos/v1/"
    fetch_interval: 30
```

The Upstream created later in Dashboard or through the Admin API must use:

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

The installer does not create this Upstream or any route because it cannot safely infer the operator's URI, host rules, or authentication policy.

## Error Handling And Safety

- Validate URLs, identifiers, ports, credentials, and Dashboard settings before changing the deployment.
- Reject privileged or publicly exposed Admin API binds unless explicitly supported by a future design.
- Preserve an existing `.env` and data directory during reruns.
- Render Compose and APISIX configuration atomically through temporary files, then set restrictive permissions.
- Run `docker compose config` before starting services when Docker is available.
- On startup failure, show bounded service logs without printing secrets.
- Use `docker compose up -d` with the generated project; never remove unrelated containers.

## Testing

Tests will cover:

- Bash syntax and option parsing;
- URL, identifier, port, and credential validation;
- generated APISIX config contains Nacos v1 discovery prefix, service defaults, and no leaked secrets;
- generated Compose topology with Dashboard disabled and enabled;
- mode `600` for `.env` and secret-bearing config files;
- rerun behavior preserving existing values;
- Compose config validation when Docker is available;
- prohibited public Admin API exposure and unsafe secret logging patterns.

Live Docker/Nacos deployment verification remains environment-dependent and is reported separately.
