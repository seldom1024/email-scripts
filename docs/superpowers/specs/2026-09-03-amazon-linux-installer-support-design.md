# Amazon Linux Installer Support Design

## Goal

Add first-class Amazon Linux support to the four installers that currently reject
`ID=amzn`:

- `install.sh`
- `install-with-npm.sh`
- `install-node.sh`
- `install-node-nacos.sh`

Support both Amazon Linux 2 and Amazon Linux 2023 without changing the existing
Ubuntu, Debian, CentOS, RHEL, Rocky Linux, or AlmaLinux behavior.

`install-nacos-sidecar.sh` and `install-apisix-nacos.sh` are outside the code-change
scope because they do not reject Linux distributions or install Docker. They will
work on Amazon Linux when Docker Engine and Docker Compose v2 are available.

## Distribution Detection

Each affected installer will accept `amzn` from `/etc/os-release` and include
Amazon Linux in its supported-distribution error message. The detected value will
remain `amzn` so later installation functions can use an explicit Amazon Linux
branch rather than treating the system as CentOS.

The implementation must not infer Amazon Linux from `ID_LIKE`; Amazon Linux has a
stable `ID=amzn`, and exact matching avoids accidentally expanding support to
untested RPM derivatives.

## Docker Engine Installation

Amazon Linux will use its native AWS package repository:

1. Select `dnf` when available, otherwise `yum`.
2. Install `ca-certificates`, `curl`, `openssl`, and `docker` from that repository.
3. Start and enable `docker.service` through the existing systemd path.
4. Verify the daemon with the existing `docker info` check.

The Amazon Linux branch must not add Docker's CentOS repository. That repository
is not the native package source for Amazon Linux and can resolve incorrectly or
introduce dependency conflicts across Amazon Linux 2 and Amazon Linux 2023.

Host-tool installation will use the same detected `dnf` or `yum` package manager.

## Docker Compose Installation

The installers will continue to accept an already working `docker compose`
command without changing it.

When Compose v2 is missing on Amazon Linux:

1. Try installing `docker-compose-plugin` with the native package manager.
2. If the package is unavailable or does not provide a working
   `docker compose`, install the official Docker Compose CLI plugin binary under
   `/usr/local/lib/docker/cli-plugins/docker-compose`.
3. Map `x86_64`/`amd64` to `x86_64` and `aarch64`/`arm64` to `aarch64`.
4. Reject unsupported architectures with a direct error instead of guessing.
5. Download over HTTPS, install atomically with executable permissions, and verify
   the result using `docker compose version`.

The fallback version will be a script constant so deployments are reproducible.
It may be overridden through `DOCKER_COMPOSE_VERSION` for controlled upgrades.
No password, token, node address, or other deployment secret will be involved in
the download URL or logs.

## Error Handling

- Report clearly when neither `dnf` nor `yum` exists on Amazon Linux.
- If native Compose installation fails, log a warning and try the official binary
  fallback instead of terminating immediately.
- Fail before downloading when the CPU architecture is unsupported.
- Preserve the existing final checks for Docker Engine and Compose availability.
- Do not change container definitions, application configuration, Nacos behavior,
  ports, credentials, or enrollment behavior.

## Testing

Add a focused shell regression test that sources each affected installer with
`INSTALLER_LIB_ONLY=1` and uses temporary fixtures and command stubs. It will prove:

- an `/etc/os-release` fixture containing `ID=amzn` is accepted;
- unsupported distribution handling still fails;
- Amazon Linux selects `dnf` when present and `yum` otherwise;
- native Docker installation requests the `docker` package and never adds the
  CentOS Docker repository;
- host tools use the selected native package manager;
- Compose first attempts the native package and then uses the official plugin
  fallback when still unavailable;
- `x86_64` and `aarch64` generate the correct download artifact name;
- unsupported architectures fail without installing a binary.

Run the new regression test, all existing installer tests, Bash syntax checks for
every installer, ShellCheck when available, and `git diff --check`. Live package
installation on both Amazon Linux releases remains a target-host verification gap
unless suitable machines are available during implementation.
