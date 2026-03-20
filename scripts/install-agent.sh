#!/bin/bash
#
# Bootstrap script for Proxmox VM templates
# Embed this in cloud-init userdata or run once when preparing base template
#
# Usage:
#   curl -fsSL https://git.example.com/raw/proxmox-agent/scripts/install-agent.sh | bash
#
# Environment variables:
#   AGENT_VERSION    - Version tag to download (default: latest)
#   AGENT_PORT       - Port for agent to listen on (default: 8080)
#   AGENT_BASE_URL   - Base URL to download agent binary
#   ALLOWED_IPS      - Comma-separated IPs/CIDRs allowed to access agent (default: allow all)
#   ALLOWED_SCRIPTS  - Comma-separated URL prefixes for allowed scripts (default: allow all)
#   ALLOWED_IPS_URL  - URL to fetch additional allowed IPs (e.g. raw GitHub file)
#   AUTO_DISABLE     - Set to "true" to disable agent after successful provision (default: false)

set -euo pipefail

AGENT_VERSION="${AGENT_VERSION:-latest}"
AGENT_PORT="${AGENT_PORT:-8080}"
AGENT_BASE_URL="${AGENT_BASE_URL:-https://github.com/LeAnhlinux/proxmox-template/releases}"
ALLOWED_IPS="${ALLOWED_IPS:-}"
ALLOWED_IPS_URL="${ALLOWED_IPS_URL:-}"
ALLOWED_SCRIPTS="${ALLOWED_SCRIPTS:-}"
AUTO_DISABLE="${AUTO_DISABLE:-false}"

INSTALL_DIR="/opt/proxmox-agent"
CONFIG_DIR="/etc/proxmox-agent"
BIN_PATH="${INSTALL_DIR}/proxmox-agent"

echo "==> Installing proxmox-agent ${AGENT_VERSION}"

# Create directories
mkdir -p "${INSTALL_DIR}/scripts"
mkdir -p /var/log/proxmox-agent
mkdir -p "${CONFIG_DIR}"

# Download binary
ARCH=$(uname -m)
case "${ARCH}" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

# "latest" uses GitHub's /releases/latest/download/ redirect
# specific version uses /releases/download/vX.Y.Z/
if [ "${AGENT_VERSION}" = "latest" ]; then
  DOWNLOAD_URL="${AGENT_BASE_URL}/latest/download/proxmox-agent-linux-${ARCH}"
else
  DOWNLOAD_URL="${AGENT_BASE_URL}/download/${AGENT_VERSION}/proxmox-agent-linux-${ARCH}"
fi
echo "==> Downloading from ${DOWNLOAD_URL}"
curl -fsSL -o "${BIN_PATH}" "${DOWNLOAD_URL}"
chmod +x "${BIN_PATH}"

# Generate security config
echo "==> Generating security config"

# Build allowed_ips JSON array
IPS_JSON="[]"
if [ -n "${ALLOWED_IPS}" ]; then
  IPS_JSON=$(echo "${ALLOWED_IPS}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
    awk 'BEGIN{printf "["} NR>1{printf ","} {printf "\"%s\"", $0} END{printf "]"}')
fi

# Build allowed_script_prefixes JSON array
SCRIPTS_JSON="[]"
if [ -n "${ALLOWED_SCRIPTS}" ]; then
  SCRIPTS_JSON=$(echo "${ALLOWED_SCRIPTS}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
    awk 'BEGIN{printf "["} NR>1{printf ","} {printf "\"%s\"", $0} END{printf "]"}')
fi

# Allowed IPs URL
ALLOWED_IPS_URL_JSON="\"${ALLOWED_IPS_URL}\""
if [ -z "${ALLOWED_IPS_URL}" ]; then
  ALLOWED_IPS_URL_JSON='""'
fi

# Auto disable boolean
AUTO_DISABLE_JSON="false"
if [ "${AUTO_DISABLE}" = "true" ]; then
  AUTO_DISABLE_JSON="true"
fi

cat > "${CONFIG_DIR}/config.json" <<EOF
{
  "allowed_ips": ${IPS_JSON},
  "allowed_ips_url": ${ALLOWED_IPS_URL_JSON},
  "allowed_script_prefixes": ${SCRIPTS_JSON},
  "auto_disable": ${AUTO_DISABLE_JSON}
}
EOF

echo "==> Config written to ${CONFIG_DIR}/config.json"
cat "${CONFIG_DIR}/config.json"

# Create systemd service
cat > /etc/systemd/system/proxmox-agent.service <<EOF
[Unit]
Description=Proxmox Provisioning Agent
After=network-online.target cloud-init.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -port ${AGENT_PORT} -log-dir /var/log/proxmox-agent -config ${CONFIG_DIR}/config.json
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=proxmox-agent

# Security hardening
NoNewPrivileges=false
ProtectSystem=false

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
systemctl daemon-reload
systemctl enable proxmox-agent
systemctl start proxmox-agent

echo "==> proxmox-agent installed and running on port ${AGENT_PORT}"
echo "==> Config: ${CONFIG_DIR}/config.json"
echo "==> Check status: systemctl status proxmox-agent"
echo "==> View logs: journalctl -u proxmox-agent -f"
