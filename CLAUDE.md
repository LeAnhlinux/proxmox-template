# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Proxmox Provisioning Agent — a lightweight Go agent that runs inside Proxmox VMs. It listens on port 8080 for provisioning commands, downloads bash scripts from a remote URL, executes them, and reports results back via a callback URL.

## Build & Run Commands

```bash
make build          # Build for current platform → bin/proxmox-agent
make build-all      # Cross-compile for Linux amd64 + arm64
make run            # Run locally on port 8080
make test           # go test ./...
make clean          # Remove bin/
```

Version/commit are injected via `-ldflags` at build time (`-X main.version`, `-X main.commit`).

## Architecture

The agent is a zero-dependency Go project (stdlib only, no external modules). Four internal packages:

- **`internal/config`** — Loads security config from `/etc/proxmox-agent/config.json`: IP allowlist, script URL allowlist, auto-disable flag.
- **`internal/server`** — HTTP server (net/http) with three endpoints: `GET /health`, `GET /status`, `POST /provision`. IP filtering middleware on `/status` and `/provision`. Provision supports sync (default) and async (`?async=true`) modes. Auto-disable after successful provision.
- **`internal/executor`** — Downloads a bash script from a URL, runs it via `/bin/bash` with environment variables injected. Only one task can run at a time (mutex-guarded status). Default timeout is 3600s. The `domain` field is injected as `$DOMAIN` env var.
- **`internal/reporter`** — Dual logging (file + stdout) and HTTP callback sender. Saves per-script logs to the log directory with timestamps.

Entry point: `cmd/agent/main.go` — wires up config → reporter → executor → server, handles graceful shutdown via SIGINT/SIGTERM.

## Key Design Decisions

- Single-task execution: the executor rejects concurrent provision requests (HTTP 409).
- Callback output is truncated to 10,000 chars (tail, not head) via `truncateOutput`.
- Scripts run as root with `DEBIAN_FRONTEND=noninteractive` set automatically.
- Agent is deployed via cloud-init (`scripts/cloud-init-userdata.yaml`) and runs as a systemd service.
- Security: IP allowlist + script URL allowlist + auto-disable after successful provision.
