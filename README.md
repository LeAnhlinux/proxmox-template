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
       └─────────────────────────────────── │  Git repo        │
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

### Download

Grab the binary from [Releases](https://github.com/LeAnhlinux/proxmox-template/releases):

```bash
# Linux amd64
curl -fsSL -o proxmox-agent https://github.com/LeAnhlinux/proxmox-template/releases/download/v1.0.0/proxmox-agent-linux-amd64
chmod +x proxmox-agent

# Run
./proxmox-agent -port 8080
```

### Build from source

```bash
make build          # Build for current platform → bin/proxmox-agent
make build-all      # Cross-compile for Linux amd64 + arm64
make test           # Run tests
```

## API Endpoints

### `GET /health`

Health check (no IP filtering, open for monitoring).

```json
{ "status": "ok", "hostname": "vm-docker-01", "agent": "proxmox-agent" }
```

### `GET /status`

Current task status (IP filtered).

```json
{ "task_status": "idle" }
```

### `POST /provision`

Execute a provisioning script (IP filtered).

```bash
curl -X POST http://VM_IP:8080/provision \
  -H "Content-Type: application/json" \
  -d '{
    "script_url": "https://raw.githubusercontent.com/your-repo/scripts/wordpress.sh",
    "domain": "app.example.com",
    "callback_url": "https://api.example.com/vm/callback",
    "env": {
      "PHP_VERSION": "8.4",
      "NODE_VERSION": "22"
    },
    "timeout": 3600
  }'
```

| Field | Required | Description |
|-------|----------|-------------|
| `script_url` | Yes | URL to the bash script to download and execute |
| `domain` | No | Injected as `$DOMAIN` env var (e.g., for Nginx vhost, SSL cert) |
| `callback_url` | No | URL to receive status callbacks |
| `env` | No | Custom environment variables passed to the script |
| `timeout` | No | Execution timeout in seconds (default: 3600) |

**Async mode** — add `?async=true`, returns immediately and reports via callback:

```bash
curl -X POST "http://VM_IP:8080/provision?async=true" \
  -H "Content-Type: application/json" \
  -d '{ "script_url": "...", "callback_url": "https://api.example.com/callback" }'
```

### Callback Payload

```json
{
  "hostname": "vm-docker-01",
  "domain": "app.example.com",
  "script": "https://raw.githubusercontent.com/.../wordpress.sh",
  "status": "success",
  "output": "... script stdout/stderr (last 10,000 chars) ...",
  "started_at": "2026-03-17T10:00:00Z",
  "ended_at": "2026-03-17T10:03:42Z",
  "duration": "3m42s"
}
```

Status values: `started`, `success`, `failed`

## Security

Three security layers, configured via `/etc/proxmox-agent/config.json`:

```json
{
  "allowed_ips": ["103.130.216.137", "10.0.0.0/24"],
  "allowed_script_prefixes": ["https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/"],
  "auto_disable": true
}
```

| Layer | Description |
|-------|-------------|
| **IP allowlist** | Only specified IPs/CIDRs can access `/provision` and `/status`. `/health` remains open. Empty = allow all. |
| **Script URL allowlist** | Only scripts matching trusted URL prefixes can execute. Empty = allow all. |
| **Auto-disable** | After successful provision, runs `systemctl disable --now proxmox-agent`. |

If no config file exists, all restrictions are disabled (allow-all).

## Setup on Proxmox

### 1. Prepare base template

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
qm set 9000 --ciuser root
qm set 9000 --sshkeys ~/.ssh/id_rsa.pub
qm set 9000 --ipconfig0 ip=dhcp
```

### 2. Add cloud-init userdata

Edit `scripts/cloud-init-userdata.yaml` with your config (allowed IPs, script prefixes, agent version), then:

```bash
qm set 9000 --cicustom "user=local:snippets/cloud-init-userdata.yaml"
qm template 9000
```

Cloud-init will run `scripts/install-agent.sh` on first boot, which downloads the binary, generates the security config, and starts the systemd service.

### 3. Provision a VM

```bash
# Clone and start
qm clone 9000 101 --name my-app-vm --full
qm start 101

# Wait for boot, then provision
curl -X POST http://VM_IP:8080/provision \
  -H "Content-Type: application/json" \
  -d '{"script_url": "https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/scripts/examples/wordpress.sh"}'
```

## Writing Provision Scripts

```bash
#!/bin/bash
set -euo pipefail

echo "==> Installing MyApp"
apt-get -y update
apt-get -y install myapp

systemctl enable myapp
echo "==> Done!"
```

- Use `set -euo pipefail` — script stops on first error
- `DEBIAN_FRONTEND=noninteractive` is set automatically by the agent
- `$DOMAIN` and custom env vars from the API request are available
- Scripts run as root, stdout/stderr is captured and sent in the callback
- See `scripts/examples/` for real-world examples

## Logs

| Log | Location |
|-----|----------|
| Agent log | `/var/log/proxmox-agent/agent.log` |
| Script logs | `/var/log/proxmox-agent/script-*.log` |
| Systemd journal | `journalctl -u proxmox-agent -f` |

## License

MIT
