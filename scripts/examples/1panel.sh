#!/bin/bash
#
# 1Panel Provisioning Script
# Installs 1Panel — modern open-source VPS control panel with Docker support
#
# Required env vars:
#   DOMAIN          - Hostname for the server (e.g. panel.example.com) — injected by agent
#
# Optional env vars:
#   PANEL_PORT      - Panel port (default: random 10000-65535)
#
# Supports: Ubuntu 20/22/24, Debian 11/12, AlmaLinux 8/9, Rocky Linux 8/9, CentOS 7/8/9

set -euo pipefail

# ─── Force non-interactive mode ──────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# ─── Variables ───────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:?DOMAIN env var is required}"
PANEL_PORT="${PANEL_PORT:-$(shuf -i 10000-65535 -n 1)}"
CREDS_FILE="/root/.1panel-credentials"
INSTALL_SCRIPT_URL="https://resource.1panel.pro/v2/quick_start.sh"

echo "=========================================="
echo "  1Panel Provisioner"
echo "  Hostname : ${DOMAIN}"
echo "  Port     : ${PANEL_PORT}"
echo "=========================================="

# ─── Wait for package manager lock ──────────────────────────────────────────

wait_for_package_manager() {
    local max_wait=300
    local waited=0

    if command -v apt-get &>/dev/null; then
        echo "==> Waiting for apt lock to be released..."
        while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock &>/dev/null 2>&1; do
            if [ "${waited}" -ge "${max_wait}" ]; then
                echo "ERROR: Timed out waiting for apt lock after ${max_wait}s"
                exit 1
            fi
            sleep 2
            waited=$((waited + 2))
        done
    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
        echo "==> Waiting for yum/dnf lock to be released..."
        while fuser /var/run/yum.pid /var/run/dnf.pid &>/dev/null 2>&1; do
            if [ "${waited}" -ge "${max_wait}" ]; then
                echo "ERROR: Timed out waiting for yum/dnf lock after ${max_wait}s"
                exit 1
            fi
            sleep 2
            waited=$((waited + 2))
        done
    fi

    if [ "${waited}" -gt 0 ]; then
        echo "==> Package manager lock released after ${waited}s"
    fi
}

# ─── Detect OS ───────────────────────────────────────────────────────────────

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
    else
        echo "ERROR: Cannot detect OS (no /etc/os-release)"
        exit 1
    fi

    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    else
        echo "ERROR: No supported package manager found"
        exit 1
    fi

    echo "==> Detected: ${OS_ID} ${OS_VERSION} (${PKG_MANAGER})"
}

# ─── Prerequisites ───────────────────────────────────────────────────────────

install_prerequisites() {
    wait_for_package_manager

    if [ "${PKG_MANAGER}" = "apt" ]; then
        dpkg --configure -a --force-confdef --force-confold || true
        apt-get update -y
        apt-get install "${APT_OPTS[@]}" curl wget tar
    else
        ${PKG_MANAGER} install -y curl wget tar
    fi

    echo "==> Prerequisites installed"
}

# ─── Install Docker (if not present) ────────────────────────────────────────

install_docker() {
    if command -v docker &>/dev/null; then
        echo "==> Docker already installed: $(docker --version)"
        return 0
    fi

    echo "==> Installing Docker..."
    curl -fsSL https://get.docker.com | bash || {
        echo "ERROR: Docker installation failed"
        exit 1
    }

    systemctl enable --now docker
    echo "==> Docker installed: $(docker --version)"
}

# ─── Install 1Panel ─────────────────────────────────────────────────────────

install_1panel() {
    echo "==> Downloading 1Panel installer..."
    cd /tmp

    curl -fsSL -o quick_start.sh "${INSTALL_SCRIPT_URL}" || {
        echo "ERROR: Failed to download 1Panel installer"
        exit 1
    }

    echo "==> Running 1Panel installer (non-interactive)..."

    # quick_start.sh downloads, extracts, and runs install.sh automatically
    # install.sh prompts timeout after a few seconds and uses defaults
    # All values are auto-generated: port, username, password, entrance
    bash quick_start.sh || {
        echo "ERROR: 1Panel installation failed"
        exit 1
    }

    # Wait for 1Panel to start
    echo "==> Waiting 10s for 1Panel to initialize..."
    sleep 10

    # Verify 1Panel is running
    if systemctl is-active --quiet 1panel 2>/dev/null; then
        echo "==> 1Panel service is running"
    else
        echo "==> 1Panel not running, starting..."
        systemctl enable --now 1panel || true
        sleep 5
    fi

    echo "==> 1Panel installation completed"
}

# ─── Save Credentials ───────────────────────────────────────────────────────

save_credentials() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    # Extract credentials from 1Panel CLI
    local panel_info=""
    local panel_user=""
    local panel_pass=""
    local panel_entrance=""

    if command -v 1pctl &>/dev/null; then
        panel_info=$(1pctl user-info 2>/dev/null || true)
        panel_user=$(echo "${panel_info}" | grep -i "username" | awk -F: '{print $2}' | xargs || echo "")
        panel_pass=$(echo "${panel_info}" | grep -i "password" | awk -F: '{print $2}' | xargs || echo "")
        panel_entrance=$(echo "${panel_info}" | grep -i "entrance" | awk -F: '{print $2}' | xargs || echo "")
    fi

    # Fallback: if 1pctl not available, try reading from config
    if [ -z "${panel_user}" ] && [ -f /opt/1panel/conf/app.yaml ]; then
        panel_user=$(grep -oP 'userName:\s*\K\S+' /opt/1panel/conf/app.yaml 2>/dev/null || echo "check 1pctl")
    fi

    local panel_url="http://${server_ip}:${PANEL_PORT}"
    if [ -n "${panel_entrance}" ]; then
        panel_url="${panel_url}/${panel_entrance}"
    fi

    cat > "${CREDS_FILE}" <<EOF
==========================================
  1Panel Installation Complete
  Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
==========================================

  Panel Access:
    URL       : ${panel_url}
    Username  : ${panel_user:-see '1pctl user-info'}
    Password  : ${panel_pass:-see '1pctl user-info'}
    Entrance  : ${panel_entrance:-see '1pctl user-info'}

  Domain    : ${DOMAIN}
  Server IP : ${server_ip}
  Port      : ${PANEL_PORT}

  First Steps:
    1. Log into panel at ${panel_url}
    2. Install apps from the App Store (Nginx, MySQL, etc.)
    3. Add your website domain
    4. Configure SSL certificate

==========================================
EOF

    chmod 600 "${CREDS_FILE}"
    echo "==> Credentials saved to ${CREDS_FILE}"
}

# ─── Welcome Screen (MOTD) ──────────────────────────────────────────────────

setup_motd() {
    echo "==> Setting up SSH welcome screen"

    chmod -x /etc/update-motd.d/* 2>/dev/null || true

    cat > /etc/update-motd.d/99-app-info <<'MOTD_SCRIPT'
#!/bin/bash
CREDS_FILE="/root/.1panel-credentials"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                     1Panel SERVER                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
if [ -f "${CREDS_FILE}" ]; then
    cat "${CREDS_FILE}"
else
    echo "  Run '1pctl user-info' to view panel credentials"
fi
echo ""
echo "  Useful Commands:"
echo "  ─────────────────────────────────────────────"
echo "  1pctl user-info         Show panel credentials"
echo "  1pctl update password   Change panel password"
echo "  1pctl listen-ip show    Show listen address"
echo "  1pctl reset entrance    Reset security entrance"
echo "  systemctl status 1panel Check service status"
echo "  cat /root/.1panel-credentials  View credentials"
echo ""
MOTD_SCRIPT

    chmod +x /etc/update-motd.d/99-app-info
    echo "==> MOTD configured"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    detect_os
    install_prerequisites
    install_docker
    install_1panel
    save_credentials
    setup_motd

    echo ""
    cat "${CREDS_FILE}"
}

main
