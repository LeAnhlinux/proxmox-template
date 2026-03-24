# Proxmox Provisioning Agent

Lightweight Go agent that runs inside Proxmox VMs. Listens on port 8080, downloads and executes bash provisioning scripts, and reports results back via callback URL.

**Zero dependencies** — stdlib only, single binary, ~6MB.

## Architecture

```
┌─────────────┐     POST /provision        ┌──────────────────┐
│  Your API   │ ──────────────────────────> │  proxmox-agent   │
│  Server     │     { script_url, ... }     │  (inside VM)     │
└─────────────┘                             └────────┬─────────┘
       ^                                             │
       │  callback (status, output)                  │ download script
       │                                             v
       │                                    ┌──────────────────┐
       └─────────────────────────────────── │  GitHub repo     │
                                            │  (bash scripts)  │
                                            └──────────────────┘
```

## How It Works

1. Clone VM from base template on Proxmox
2. VM boots → cloud-init runs `install-agent.sh` → starts `proxmox-agent` as systemd service
3. Your API sends `POST /provision` with the script URL
4. Agent downloads script → executes via `/bin/bash` with env vars injected
5. Agent reports result back via callback URL + saves local log
6. (Optional) Agent auto-disables itself after successful provision

## Quick Start

### Install via cloud-init (recommended)

Embed in `cloud.cfg` runcmd:

```yaml
runcmd:
  - |
    AGENT_VERSION="latest"
    AGENT_BASE_URL="https://github.com/LeAnhlinux/proxmox-template/releases"
    INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/scripts/install-agent.sh"
    AGENT_PORT=8080
    ALLOWED_IPS="103.130.216.137"
    ALLOWED_IPS_URL="https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/config/allowed-ips.txt"
    ALLOWED_SCRIPTS="https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/"
    AUTO_DISABLE="true"
    curl -fsSL "${INSTALL_SCRIPT_URL}" | \
      AGENT_VERSION="${AGENT_VERSION}" \
      AGENT_BASE_URL="${AGENT_BASE_URL}" \
      AGENT_PORT="${AGENT_PORT}" \
      ALLOWED_IPS="${ALLOWED_IPS}" \
      ALLOWED_IPS_URL="${ALLOWED_IPS_URL}" \
      ALLOWED_SCRIPTS="${ALLOWED_SCRIPTS}" \
      AUTO_DISABLE="${AUTO_DISABLE}" \
      bash
```

### Install manually

```bash
curl -fsSL https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/scripts/install-agent.sh | \
  AGENT_VERSION="latest" ALLOWED_IPS="YOUR_IP" AUTO_DISABLE="true" bash
```

### Build from source

```bash
make build          # Build for current platform → bin/proxmox-agent
make build-all      # Cross-compile for Linux amd64 + arm64
make test           # Run tests
```

## API Endpoints

### `GET /health`

Health check — open for monitoring, **no IP filter**.

```json
{ "status": "ok", "hostname": "vm-01", "agent": "proxmox-agent" }
```

### `GET /status`

Current task status — **IP filtered**.

```json
{ "task_status": "idle" }
```

### `POST /provision`

Execute a provisioning script — **IP filtered**.

**Sync mode** (default) — blocks until script completes:

```bash
curl -X POST http://VM_IP:8080/provision \
  -H "Content-Type: application/json" \
  -d '{
    "script_url": "https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/scripts/template/wordpress.sh",
    "domain": "app.example.com",
    "callback_url": "https://api.example.com/vm/callback",
    "env": {
      "DB_NAME": "mydb",
      "DB_USER": "myuser"
    },
    "timeout": 3600
  }'
```

**Async mode** — returns immediately, reports via callback:

```bash
curl -X POST "http://VM_IP:8080/provision?async=true" \
  -H "Content-Type: application/json" \
  -d '{ "script_url": "...", "callback_url": "https://api.example.com/callback" }'
```

#### Request fields

| Field | Required | Description |
|-------|----------|-------------|
| `script_url` | ✅ | URL to bash script to download and execute |
| `domain` | — | Injected as `$DOMAIN` env var |
| `callback_url` | — | URL to receive status callbacks (started/success/failed) |
| `env` | — | Custom environment variables passed to the script |
| `timeout` | — | Execution timeout in seconds (default: 3600) |

#### Response codes

| Code | Meaning |
|------|---------|
| 200 | Sync provision success |
| 202 | Async provision accepted |
| 400 | Bad request (missing script_url, invalid JSON) |
| 403 | IP not allowed or script URL not in allowlist |
| 409 | Another task is already running |
| 500 | Script execution failed |

### Callback Payload

Sent to `callback_url` on status change:

```json
{
  "hostname": "vm-01",
  "domain": "app.example.com",
  "script": "https://raw.githubusercontent.com/.../wordpress.sh",
  "status": "success",
  "output": "... last 10,000 chars of stdout/stderr ...",
  "started_at": "2026-03-17T10:00:00Z",
  "ended_at": "2026-03-17T10:03:42Z",
  "duration": "3m42s"
}
```

Status values: `started` → `success` | `failed`

## Security

Three layers, configured via `/etc/proxmox-agent/config.json`:

```json
{
  "allowed_ips": ["103.130.216.137"],
  "allowed_ips_url": "https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/config/allowed-ips.txt",
  "allowed_script_prefixes": ["https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/"],
  "auto_disable": true
}
```

| Layer | Description |
|-------|-------------|
| **IP Allowlist (local)** | IPs/CIDRs in `allowed_ips`. Applies to `/provision` and `/status`. `/health` always open. |
| **IP Allowlist (remote)** | Agent fetches `allowed_ips_url` every 5 minutes. Edit on GitHub, no rebuild needed. Format: one IP/CIDR per line, `#` for comments. |
| **Script URL Prefix** | Only scripts matching `allowed_script_prefixes` can execute. |
| **Auto-disable** | After successful provision, runs `systemctl disable --now proxmox-agent`. |

**No config file = allow all** (backward compatible).

### Remote IP Allowlist (`config/allowed-ips.txt`)

```txt
# Management servers
103.130.216.137
103.130.216.58
103.241.42.10

# Office network
192.168.1.0/24
```

Edit this file on GitHub → agent auto-fetches every 5 minutes.

## CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `-port` | 8080 | HTTP listen port |
| `-log-dir` | `/var/log/proxmox-agent` | Log directory |
| `-config` | `/etc/proxmox-agent/config.json` | Config file path |
| `-version` | — | Print version and exit |

## Install Script Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_VERSION` | `latest` | Release tag (`v1.1.0`) or `latest` |
| `AGENT_BASE_URL` | GitHub releases URL | Base URL for binary download |
| `AGENT_PORT` | `8080` | Agent listen port |
| `ALLOWED_IPS` | — | Comma-separated IPs/CIDRs |
| `ALLOWED_IPS_URL` | — | Remote IP allowlist URL |
| `ALLOWED_SCRIPTS` | — | Comma-separated URL prefixes |
| `AUTO_DISABLE` | `false` | Set `true` to auto-disable after provision |

## Provision Flow

```
POST /provision
    │
    ├── IP filter → 403 if blocked
    ├── Validate JSON → 400 if invalid
    ├── Script URL check → 403 if not in allowlist
    ├── Mutex check → 409 if task running
    │
    ├── Send "started" callback
    ├── Download script → /opt/proxmox-agent/scripts/
    ├── Execute: /bin/bash <script>
    │     Environment:
    │       DEBIAN_FRONTEND=noninteractive
    │       LC_ALL=C
    │       DOMAIN=<value>
    │       <custom env vars>
    │
    ├── Capture stdout+stderr
    ├── Truncate output to last 10,000 chars (for callback)
    ├── Send "success"/"failed" callback
    ├── Save log → /var/log/proxmox-agent/script-<name>-<timestamp>.log
    │
    └── If success + auto_disable:
          sleep 2s → systemctl disable --now proxmox-agent
```

## Available Provisioning Scripts

### Control Panel (`scripts/panel/`)

| Script | Description |
|--------|-------------|
| `1panel.sh` | [1Panel](https://1panel.pro) — modern server management panel |
| `aapanel.sh` | [aaPanel](https://aapanel.com) — web hosting control panel |
| `cpanel.sh` | [cPanel](https://cpanel.net) — commercial hosting panel (requires license) |

### App Templates (`scripts/template/`)

| Script | Description |
|--------|-------------|
| `wordpress.sh` | WordPress + Nginx + PHP 8.4 + MariaDB + SSL |
| `openlitespeed-wp.sh` | WordPress + OpenLiteSpeed + MariaDB + SSL |
| `odoo-18-ubuntu.sh` | Odoo 18 ERP + PostgreSQL 16 + Nginx + SSL |
| `vtiger-ubuntu.sh` | Vtiger CRM + Apache + PHP + MySQL + SSL |
| `coolify.sh` | Coolify self-hosted PaaS + Docker |

### Usage example

```bash
# WordPress with Nginx
curl -X POST http://VM_IP:8080/provision \
  -H "Content-Type: application/json" \
  -d '{
    "script_url": "https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/scripts/template/wordpress.sh",
    "domain": "blog.example.com"
  }'

# 1Panel
curl -X POST "http://VM_IP:8080/provision?async=true" \
  -H "Content-Type: application/json" \
  -d '{
    "script_url": "https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/scripts/panel/1panel.sh",
    "domain": "panel.example.com"
  }'
```

## Logs

| Log | Location |
|-----|----------|
| Agent log | `/var/log/proxmox-agent/agent.log` |
| Script logs | `/var/log/proxmox-agent/script-<name>-<timestamp>.log` |
| Systemd journal | `journalctl -u proxmox-agent -f` |

## Proxmox Template Setup

### 1. Create base VM

```bash
# Download Ubuntu cloud image
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Create VM
qm create 9000 --name ubuntu-24-04-base --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 noble-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1
qm set 9000 --ciuser root --sshkeys ~/.ssh/id_rsa.pub --ipconfig0 ip=dhcp
```

### 2. Add cloud-init runcmd

Edit `/var/lib/vz/snippets/cloud.cfg` (or embed in template) with the agent install runcmd shown in Quick Start.

### 3. Convert to template

```bash
qm template 9000
```

### 4. Clone and provision

```bash
qm clone 9000 101 --name my-app --full
qm start 101
# Wait for boot + cloud-init, then:
curl -X POST http://VM_IP:8080/provision -H "Content-Type: application/json" \
  -d '{"script_url": "...", "domain": "app.example.com"}'
```

## Release

```bash
make build-all
gh release create vX.Y.Z bin/proxmox-agent-linux-amd64 bin/proxmox-agent-linux-arm64 \
  --title "vX.Y.Z - Title" --notes "changelog"
```

## License

MIT
