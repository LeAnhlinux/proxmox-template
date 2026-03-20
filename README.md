# Proxmox Provisioning Agent

Lightweight Go agent that runs inside Proxmox VMs. Listens on port 8080, waits for your API to send a provisioning command, downloads a bash script from your git repo, executes it, and reports back.

## Architecture

```
┌─────────────┐     POST /provision        ┌──────────────────┐
│  Your API   │ ──────────────────────────> │  proxmox-agent   │
│  Server     │     { script_url, ... }     │  (inside VM)     │
└─────────────┘                             └────────┬─────────┘
       ^                                             │
       │  callback (status, output)                  │ curl raw URL
       │                                             v
       │                                    ┌──────────────────┐
       └─────────────────────────────────── │  Git repo        │
                                            │  (bash scripts)  │
                                            └──────────────────┘
```

## Flow

1. Clone VM from base template on Proxmox
2. VM boots → cloud-init downloads & starts `proxmox-agent`
3. Your API sends `POST /provision` with the script URL
4. Agent downloads script from git raw URL → executes it
5. Agent reports result back via callback URL + local log

## API Endpoints

### `GET /health`

```json
{ "status": "ok", "hostname": "vm-docker-01", "agent": "proxmox-agent" }
```

### `GET /status`

```json
{ "task_status": "idle" }
```

### `POST /provision`

Execute a provisioning script.

```bash
curl -X POST http://VM_IP:8080/provision \
  -H "Content-Type: application/json" \
  -d '{
    "script_url": "https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/scripts/examples/docker.sh",
    "domain": "app.example.com",
    "callback_url": "https://api.example.com/vm/callback",
    "env": {
      "DOCKER_COMPOSE_VERSION": "v2.29.1",
      "NODE_VERSION": "22"
    },
    "timeout": 3600
  }'
```

The `domain` field is automatically injected as the `$DOMAIN` environment variable, so any script can use it (e.g., to configure Nginx vhost, request SSL cert, set hostname).

**Async mode** (returns immediately, reports via callback):

```bash
curl -X POST "http://VM_IP:8080/provision?async=true" \
  -H "Content-Type: application/json" \
  -d '{ "script_url": "...", "callback_url": "..." }'
```

**Callback payload** (sent to your API):

```json
{
  "hostname": "vm-docker-01",
  "domain": "app.example.com",
  "script": "https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/scripts/examples/docker.sh",
  "status": "success",
  "output": "... script stdout/stderr ...",
  "started_at": "2026-03-17T10:00:00Z",
  "ended_at": "2026-03-17T10:03:42Z",
  "duration": "3m42s"
}
```

Status values: `started`, `running`, `success`, `failed`

## Security

The agent supports three security layers, configured via `/etc/proxmox-agent/config.json`:

```json
{
  "allowed_ips": ["103.130.216.137"],
  "allowed_script_prefixes": ["https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/"],
  "auto_disable": true
}
```

- **IP allowlist** — only requests from specified IPs/CIDRs can reach `/provision` and `/status`. The `/health` endpoint remains open for monitoring.
- **Script URL allowlist** — only scripts from trusted URL prefixes are allowed to execute. Blocks arbitrary script injection.
- **Auto-disable** — after successful provisioning, the agent runs `systemctl disable --now proxmox-agent` to shut itself down. No more open port.

All three settings are injected via cloud-init environment variables (`ALLOWED_IPS`, `ALLOWED_SCRIPTS`, `AUTO_DISABLE`) during VM creation.

## Setup on Proxmox

### 1. Build the agent

```bash
make build-all
# Output: bin/proxmox-agent-linux-amd64, bin/proxmox-agent-linux-arm64
```

### 2. Host the binary

Upload `proxmox-agent-linux-amd64` to your git repo releases or any HTTP server.

### 3. Prepare base Ubuntu template

```bash
# On Proxmox host
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

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

### 4. Add cloud-init userdata

Edit `scripts/cloud-init-userdata.yaml` with your URLs, then:

```bash
# Set userdata on the template
qm set 9000 --cicustom "user=local:snippets/agent-userdata.yaml"
# Then convert to template
qm template 9000
```

### 5. Use it

```bash
# Clone a new VM
qm clone 9000 101 --name my-docker-vm --full
qm start 101

# Wait for VM to boot + agent to start, then provision
curl -X POST http://VM_IP:8080/provision \
  -d '{"script_url": "https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/scripts/examples/docker.sh"}'
```

## Writing Provision Scripts

Each template is a single bash script. Keep it simple:

```bash
#!/bin/bash
set -euo pipefail

echo "==> Installing MyApp"
apt-get -y update
apt-get -y install myapp

systemctl enable myapp
echo "==> Done!"
```

Tips:
- Always use `set -euo pipefail` at the top
- Use `DEBIAN_FRONTEND=noninteractive` (agent sets this automatically)
- Use env vars for configurable values (passed via `env` in the API request)
- Scripts run as root
- All stdout/stderr is captured and sent in the callback

## Example Scripts

See `scripts/examples/`:
- `wordpress.sh` — WordPress + Nginx + PHP 8.4 + MariaDB + SSL (supports Ubuntu & AlmaLinux)

## Logs

- Agent log: `/var/log/proxmox-agent/agent.log`
- Script logs: `/var/log/proxmox-agent/script-*.log`
- Systemd: `journalctl -u proxmox-agent -f`
