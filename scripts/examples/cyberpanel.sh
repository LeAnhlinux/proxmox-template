#!/bin/bash
#
# CyberPanel Provisioning Script
# Installs: CyberPanel + OpenLiteSpeed + MariaDB + PHP + PureFTPd + Postfix + SSL
#
# Required env vars:
#   DOMAIN          - Hostname for the server (e.g. panel.example.com) — injected by agent
#
# Optional env vars:
#   PANEL_PASS      - Admin password (default: random 16-char)
#   INSTALL_ADDONS  - Install Memcached + Redis (default: false, set "true" to enable)
#
# Supports: Ubuntu 22.04, Ubuntu 24.04

set -euo pipefail

# ─── Force non-interactive mode ──────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# ─── Variables ───────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:?DOMAIN env var is required}"
PANEL_PASS=""
INSTALL_ADDONS="${INSTALL_ADDONS:-false}"
PANEL_PORT="8090"
CREDS_FILE="/root/.cyberpanel-credentials"
INSTALL_SCRIPT_URL="https://cyberpanel.net/install.sh"

echo "=========================================="
echo "  CyberPanel Provisioner"
echo "  Hostname : ${DOMAIN}"
echo "  Port     : ${PANEL_PORT}"
echo "  Password : random (auto-generated)"
echo "  Addons   : ${INSTALL_ADDONS}"
echo "=========================================="

# ─── Wait for package manager lock ──────────────────────────────────────────

wait_for_apt() {
    local waited=0
    echo "==> Waiting for apt lock to be released..."
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        sleep 2
        waited=$((waited + 2))
    done
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
        echo "ERROR: Cannot detect OS"
        exit 1
    fi

    case "${OS_ID}" in
        ubuntu)
            case "${OS_VERSION}" in
                22.04|24.04) echo "==> Detected: ${OS_ID} ${OS_VERSION}" ;;
                *) echo "ERROR: Ubuntu ${OS_VERSION} not supported. Use 22.04 or 24.04"; exit 1 ;;
            esac
            ;;
        *)
            echo "ERROR: ${OS_ID} not supported by this script. Use Ubuntu 22.04/24.04"
            exit 1
            ;;
    esac
}

# ─── Install dependencies ───────────────────────────────────────────────────

install_dependencies() {
    # Fix broken dpkg state from prior runs
    dpkg --configure -a --force-confdef --force-confold || true

    echo "==> Installing dependencies..."
    apt-get update -y
    apt-get install "${APT_OPTS[@]}" curl wget cron

    echo "==> Dependencies installed"
}

# ─── Install CyberPanel ─────────────────────────────────────────────────────

install_cyberpanel() {
    echo "==> Downloading CyberPanel installer..."
    cd /tmp

    curl -fsSL -o cyberpanel.sh "${INSTALL_SCRIPT_URL}" || {
        echo "ERROR: Failed to download CyberPanel installer"
        exit 1
    }

    echo "==> Running CyberPanel installer (non-interactive)..."
    echo "    Edition : OpenLiteSpeed"
    echo "    Password: random (auto-generated)"
    echo "    Addons  : ${INSTALL_ADDONS}"

    # Build install command
    # -v ols     = OpenLiteSpeed (free)
    # -p random  = auto-generate 16-digit random password
    # -a         = install addons (memcached, redis)
    local install_cmd="sh /tmp/cyberpanel.sh -v ols -p random"

    if [ "${INSTALL_ADDONS}" = "true" ]; then
        install_cmd="${install_cmd} -a"
    fi

    # Capture output to parse credentials
    INSTALL_LOG="/tmp/cyberpanel-install.log"
    eval "${install_cmd}" 2>&1 | tee "${INSTALL_LOG}" || {
        echo "ERROR: CyberPanel installation failed"
        exit 1
    }

    # Parse password from installer output
    PANEL_PASS=$(grep -oP 'Admin password:\s*\K\S+' "${INSTALL_LOG}" 2>/dev/null || \
                 grep -oP 'password:\s*\K\S+' "${INSTALL_LOG}" 2>/dev/null || \
                 echo "see /usr/local/CyberPanel")

    # Wait for services to initialize
    echo "==> Waiting 15s for CyberPanel services to initialize..."
    sleep 15

    # Check if CyberPanel is running
    if systemctl is-active --quiet lscpd 2>/dev/null; then
        echo "==> CyberPanel service (lscpd) is running"
    else
        echo "==> CyberPanel not running, starting..."
        systemctl enable --now lscpd || true
        sleep 5
    fi

    # Check OpenLiteSpeed
    if systemctl is-active --quiet lsws 2>/dev/null; then
        echo "==> OpenLiteSpeed is running"
    else
        echo "==> OpenLiteSpeed not running, starting..."
        systemctl enable --now lsws || true
        sleep 3
    fi

    echo "==> CyberPanel installation completed"
}

# ─── Save Credentials ───────────────────────────────────────────────────────

save_credentials() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    cat > "${CREDS_FILE}" <<CREDS
==========================================
  CyberPanel
  Created: $(date)
==========================================

  Panel Access:
    URL        : https://${server_ip}:${PANEL_PORT}
    Username   : admin
    Password   : ${PANEL_PASS}

  Domain     : ${DOMAIN}
  Server IP  : ${server_ip}

  Components:
    OpenLiteSpeed  : https://${server_ip}:7080
    MariaDB        : localhost:3306
    PureFTPd       : port 21
    Postfix        : port 25/587

  Paths:
    Web Root       : /home/${DOMAIN}/public_html
    CyberPanel     : /usr/local/CyberPanel
    OpenLiteSpeed  : /usr/local/lsws
    Logs           : /home/cyberpanel/error-logs.txt

  First Steps:
    1. Log into panel at https://${server_ip}:${PANEL_PORT}
    2. Create a website for ${DOMAIN}
    3. Issue SSL from CyberPanel dashboard
    4. Upload files or install WordPress from panel

==========================================
CREDS

    chmod 600 "${CREDS_FILE}"
    echo "==> Credentials saved to ${CREDS_FILE}"
}

# ─── Welcome Screen (MOTD) ──────────────────────────────────────────────────

setup_motd() {
    echo "==> Setting up SSH welcome screen"

    local motd_script='#!/bin/bash
CREDS_FILE="/root/.cyberpanel-credentials"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    CYBERPANEL SERVER                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
if [ -f "${CREDS_FILE}" ]; then
    cat "${CREDS_FILE}"
else
    echo "  Credentials file not found: ${CREDS_FILE}"
fi
echo ""
echo "  Useful Commands:"
echo "  ─────────────────────────────────────────────"
echo "  systemctl status lscpd          CyberPanel status"
echo "  systemctl restart lscpd         Restart CyberPanel"
echo "  systemctl status lsws           OpenLiteSpeed status"
echo "  /usr/local/lsws/bin/lswsctrl restart  Restart OLS"
echo "  cyberpanel --help               CyberPanel CLI"
echo "  certbot certificates            SSL certificate info"
echo ""
'

    # Disable default MOTD scripts
    chmod -x /etc/update-motd.d/* 2>/dev/null || true

    printf '%s' "${motd_script}" > /etc/update-motd.d/99-cyberpanel-info
    chmod +x /etc/update-motd.d/99-cyberpanel-info

    echo "==> MOTD configured"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    detect_os
    wait_for_apt
    install_dependencies
    install_cyberpanel
    save_credentials
    setup_motd

    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo "=========================================="
    echo "  CyberPanel installed!"
    echo "  Panel    : https://${server_ip}:${PANEL_PORT}"
    echo "  Username : admin"
    echo "  Password : ${PANEL_PASS}"
    echo "  Creds    : ${CREDS_FILE}"
    echo "=========================================="
}

main "$@"
