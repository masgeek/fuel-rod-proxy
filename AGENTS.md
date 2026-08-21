# Repository Guide

## Source Of Truth

- This is a collection of independent Docker Compose projects under `stacks/<name>/`, not an application with a repository-wide build or test suite.
- Trust compose files, stack `.env.example` files, Caddyfiles, and scripts over `README.md`, `CLAUDE.md`, and `docs/deployment.md`; those guides still describe older Traefik, Redis, network, and volume layouts.
- Public HTTP services currently bind host ports, usually on `127.0.0.1`, and are routed by snippets in `stacks/<name>/Caddyfile`. Compose files do not define Traefik labels. Merge snippets into the host Caddyfile rather than editing an assumed generated config.

## Validate Changes

- Use the stack's actual `.env`; `${VAR:?message}` in Compose is authoritative because several examples omit or misname required variables.
- Validate one stack without printing resolved secrets:
  `docker compose --env-file stacks/<stack>/.env -f stacks/<stack>/docker-compose.yml config --quiet`
- Inspect focused output with `config --services` or `config --images`. Operate on one service with `up -d <service>`, `logs -f <service>`, or `ps` using the same `--env-file` and `-f` arguments.
- Do not add `--project-directory .`: bind sources such as `../../config/...` and stack-local environment loading rely on the stack directory as the project base.
- Shell-only verification is `bash -n scripts/*.sh config/init/pgsql/*.sh`; use `shellcheck` when installed. Preserve LF endings for shell files (`.gitattributes`).
- Validate a stack Caddyfile with `caddy adapt --config stacks/<stack>/Caddyfile --adapter caddyfile`; validate the merged host config before reload with `caddy validate --config /etc/caddy/Caddyfile`.

## Runtime Wiring

- `dokploy-network` is external and must already exist; without Dokploy create it with `docker network create dokploy-network`.
- Deploy `databases` before PostgreSQL/MariaDB consumers and deploy `cache` separately before Redis consumers. Redis is not part of `databases`.
- PostgreSQL files in `config/init/pgsql/` and `ADDITIONAL_DBS` run only when `pgdata-main` is empty. Later environment changes do not create databases automatically.
- The network key `internal` usually has explicit `name: internal`, so it is shared across Compose projects despite older docs calling it private per-stack.
- Explicit container, network, and volume names bypass Compose project isolation; do not assume parallel copies of a stack are safe.
- Application logs are emitted to Docker stdout and collected by Alloy through the Docker socket. Farm's `uploads` and Fuelrod's `fuelrod-uploads` remain separate data volumes.
- Do not assume host ports are private: PostgreSQL `5432`, MariaDB `3306`, MSSQL `1433`, and Mailpit SMTP `1025` currently bind all interfaces.

## Safety And Workflow

- Never commit real `.env` files, root `.backup`, credentials, certificates, logs, uploads, downloads, or database backup/restore data. `.Renviron` is not ignored, and the Agwise Compose file currently does not load it.
- Do not run `scripts/dokploy-uninstaller.sh` during normal work; it removes all Docker containers, networks, volumes, configs, and secrets on the host.
- Do not run `scripts/auto-git-backup.sh` during normal work; it stages all files, commits, rebases, pushes, changes global Git configuration, and may remove a Git lock.
- Commit only when requested. Use Conventional Commits and split unrelated changes; `fix:` drives patch releases, `feat:` minor releases, and breaking changes must use `!` and/or a `BREAKING CHANGE:` footer.
- Both `.github/workflows/release.yml` and `bump-and-tag.yml` currently tag and release on pushes to `main`; account for both when changing release automation.
- If the SonarQube MCP is available, follow `.github/instructions/sonarqube_mcp.instructions.md`, including disabling automatic analysis during edits and analyzing changed code before re-enabling it.
