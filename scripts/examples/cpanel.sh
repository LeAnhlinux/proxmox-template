#!/bin/bash
#
# cPanel & WHM Provisioning Script
# Installs cPanel & WHM on a fresh server
#
# Required env vars:
#   DOMAIN          - Hostname for the server (e.g. server1.example.com) — injected by agent
#
# Optional env vars:
#   CPANEL_SKIP_CHECK - Set to "true" to skip hardware checks (default: false)
#
# Supports: AlmaLinux 8/9/10, Rocky Linux 8/9, Ubuntu 22.04/24.04
#
# Requirements:
#   - Fresh OS install (no other control panels or web servers)
#   - Minimum 2 GB RAM (4 GB recommended)
#   - Minimum 20 GB disk (40 GB recommended)
#   - Public static IP with working DNS
#   - Root access

set -euo pipefail

# ─── Force non-interactive mode ──────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# ─── Variables ───────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:?DOMAIN env var is required}"
CPANEL_SKIP_CHECK="${CPANEL_SKIP_CHECK:-false}"
INSTALLER_URL="https://securedownloads.cpanel.net/latest"
CREDS_FILE="/root/.cpanel-info"

echo "=========================================="
echo "  cPanel & WHM Provisioner"
echo "  Hostname : ${DOMAIN}"
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
        OS_MAJOR="${VERSION_ID%%.*}"
    else
        echo "ERROR: Cannot detect OS (no /etc/os-release)"
        exit 1
    fi

    case "${OS_ID}" in
        ubuntu)
            if [[ "${OS_VERSION}" != "22.04" && "${OS_VERSION}" != "24.04" ]]; then
                echo "ERROR: cPanel requires Ubuntu 22.04 or 24.04 (detected: ${OS_VERSION})"
                exit 1
            fi
            PKG_MANAGER="apt"
            ;;
        almalinux|rocky)
            if [[ "${OS_MAJOR}" -lt 8 || "${OS_MAJOR}" -gt 10 ]]; then
                echo "ERROR: cPanel requires AlmaLinux/Rocky 8, 9, or 10 (detected: ${OS_VERSION})"
                exit 1
            fi
            PKG_MANAGER="dnf"
            ;;
        *)
            echo "ERROR: Unsupported OS: ${OS_ID} ${OS_VERSION}"
            exit 1
            ;;
    esac

    echo "==> Detected: ${OS_ID} ${OS_VERSION} (${PKG_MANAGER})"
}

# ─── Hardware checks ────────────────────────────────────────────────────────

check_requirements() {
    if [ "${CPANEL_SKIP_CHECK}" = "true" ]; then
        echo "==> Skipping hardware checks (CPANEL_SKIP_CHECK=true)"
        return
    fi

    echo "==> Checking hardware requirements..."

    # Check RAM (minimum 2 GB)
    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_mb=$((ram_kb / 1024))
    echo "    RAM: ${ram_mb} MB"
    if [ "${ram_mb}" -lt 1800 ]; then
        echo "ERROR: cPanel requires minimum 2 GB RAM (detected: ${ram_mb} MB)"
        exit 1
    fi
    if [ "${ram_mb}" -lt 3800 ]; then
        echo "    WARNING: 4 GB RAM recommended for production use"
    fi

    # Check disk (minimum 20 GB)
    local disk_gb
    disk_gb=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
    echo "    Disk available: ${disk_gb} GB"
    if [ "${disk_gb}" -lt 20 ]; then
        echo "ERROR: cPanel requires minimum 20 GB free disk (detected: ${disk_gb} GB)"
        exit 1
    fi
    if [ "${disk_gb}" -lt 40 ]; then
        echo "    WARNING: 40 GB disk recommended for production use"
    fi

    # Check architecture
    local arch
    arch=$(uname -m)
    if [ "${arch}" != "x86_64" ]; then
        echo "ERROR: cPanel requires x86_64 architecture (detected: ${arch})"
        exit 1
    fi

    echo "==> Hardware checks passed"
}

# ─── Pre-install setup ───────────────────────────────────────────────────────

pre_install() {
    # Disable conflicting services
    echo "==> Disabling conflicting services..."
    for svc in apache2 httpd nginx mysql mysqld mariadb postfix dovecot named bind9; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            echo "    Stopping ${svc}..."
            systemctl stop "${svc}" || true
            systemctl disable "${svc}" || true
        fi
    done

    # Install prerequisites
    wait_for_package_manager

    if [ "${PKG_MANAGER}" = "apt" ]; then
        dpkg --configure -a --force-confdef --force-confold || true
        apt-get update -y
        apt-get install "${APT_OPTS[@]}" curl perl wget gnupg
    else
        dnf install -y curl perl wget gnupg2
    fi

    # Disable SELinux if on RHEL-based
    if [ "${PKG_MANAGER}" = "dnf" ] && [ -f /etc/selinux/config ]; then
        if getenforce 2>/dev/null | grep -qi "enforcing"; then
            echo "==> Disabling SELinux (incompatible with cPanel)..."
            setenforce 0 || true
            sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
        fi
    fi

    # Disable NetworkManager if on RHEL-based (cPanel recommendation)
    if [ "${PKG_MANAGER}" = "dnf" ]; then
        if systemctl is-active --quiet NetworkManager 2>/dev/null; then
            echo "==> Disabling NetworkManager..."
            systemctl stop NetworkManager || true
            systemctl disable NetworkManager || true
        fi
    fi
}

# ─── Install cPanel ─────────────────────────────────────────────────────────

install_cpanel() {
    echo "==> Downloading cPanel & WHM installer..."
    cd /home
    curl -fsSL -o latest "${INSTALLER_URL}"

    echo "==> Starting cPanel & WHM installation..."
    echo "    This will take 30-60 minutes. Please be patient."

    # Run installer (non-interactive, force mode)
    sh latest --force 2>&1

    echo "==> cPanel & WHM installation completed"
}

# ─── Post-install ────────────────────────────────────────────────────────────

post_install() {
    echo "==> Running post-install tasks..."

    # Get server IP
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    # Save access info
    cat > "${CREDS_FILE}" <<EOF
==========================================
  cPanel & WHM Installation Complete
==========================================

  WHM Access:
    URL:  https://${server_ip}:2087
    User: root
    Pass: (use your root SSH password)

  cPanel Access:
    URL:  https://${server_ip}:2083

  Hostname: ${DOMAIN}
  Server IP: ${server_ip}

  First Steps:
    1. Log into WHM at https://${server_ip}:2087
    2. Complete the initial setup wizard
    3. Enter your cPanel license key
    4. Create your first hosting account

  Installed: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
==========================================
EOF
    chmod 600 "${CREDS_FILE}"

    echo "==> Access info saved to ${CREDS_FILE}"
}

# ─── Welcome Screen (MOTD) ───────────────────────────────────────────────────

setup_motd() {
    echo "==> Setting up SSH welcome screen"

    # Disable default MOTD components
    chmod -x /etc/update-motd.d/* 2>/dev/null || true

    cat > /etc/update-motd.d/99-app-info <<'MOTD_SCRIPT'
#!/bin/bash
CREDS_FILE="/root/.cpanel-info"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  cPanel & WHM SERVER                        ║"
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
echo "  whmapi1 version                WHM API"
echo "  /usr/local/cpanel/cpkeyclt     License check"
echo "  /scripts/restartsrv_httpd      Restart Apache"
echo "  cat /root/.cpanel-info         View info"
echo ""
MOTD_SCRIPT

    chmod +x /etc/update-motd.d/99-app-info
    echo "==> MOTD configured"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    detect_os
    check_requirements
    pre_install
    install_cpanel
    post_install
    setup_motd

    echo ""
    cat "${CREDS_FILE}"
}

main
