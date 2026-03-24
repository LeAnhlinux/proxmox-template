#!/bin/bash
#
# Coolify Provisioning Script
# Installs: Coolify (self-hosted PaaS) + Docker
#
# Required env vars:
#   DOMAIN          - Domain name (e.g. coolify.example.com) — injected by agent
#
# Optional env vars:
#   COOLIFY_PORT    - Dashboard port (default: 8000)
#
# Requirements: 2 CPU cores, 2GB RAM, 30GB disk
# Supports: Ubuntu 22/24, Debian 11/12

set -euo pipefail

# ─── Force non-interactive mode ──────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# ─── Variables ───────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:?DOMAIN env var is required}"
COOLIFY_PORT="${COOLIFY_PORT:-8000}"
CREDS_FILE="/root/.coolify-credentials"

echo "=========================================="
echo "  Coolify Provisioner"
echo "  Domain : ${DOMAIN}"
echo "  Port   : ${COOLIFY_PORT}"
echo "=========================================="

# ─── Apt lock wait ───────────────────────────────────────────────────────────

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
    echo "==> Detected: ${OS_ID} ${OS_VERSION}"
}

# ─── Check requirements ─────────────────────────────────────────────────────

check_requirements() {
    echo "==> Checking system requirements..."

    local cpu_cores
    cpu_cores=$(nproc)
    if [ "${cpu_cores}" -lt 2 ]; then
        echo "WARNING: Coolify requires at least 2 CPU cores (found: ${cpu_cores})"
    fi

    local total_ram_mb
    total_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [ "${total_ram_mb}" -lt 1800 ]; then
        echo "WARNING: Coolify requires at least 2GB RAM (found: ${total_ram_mb}MB)"
    fi

    echo "==> System: ${cpu_cores} CPU cores, ${total_ram_mb}MB RAM"
}

# ─── Install dependencies ───────────────────────────────────────────────────

install_dependencies() {
    # Fix broken dpkg state from prior runs
    dpkg --configure -a --force-confdef --force-confold || true

    echo "==> Installing dependencies..."
    apt-get update -y
    apt-get install "${APT_OPTS[@]}" \
        curl wget git jq openssl \
        certbot cron

    echo "==> Dependencies installed"
}

# ─── Install Coolify ─────────────────────────────────────────────────────────

install_coolify() {
    echo "==> Installing Coolify..."

    # Coolify's official installer handles Docker + everything
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash || {
        echo "ERROR: Coolify installation failed"
        exit 1
    }

    # Wait for Coolify to start
    echo "==> Waiting 15s for Coolify to initialize..."
    sleep 15

    # Verify Coolify is running
    local retries=0
    while ! curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${COOLIFY_PORT}" 2>/dev/null | grep -qE "200|302|301"; do
        sleep 5
        retries=$((retries + 1))
        if [ "${retries}" -ge 12 ]; then
            echo "WARNING: Coolify may not have started yet, continuing..."
            break
        fi
        echo "==> Waiting for Coolify... (${retries}/12)"
    done

    echo "==> Coolify installed"
}

# ─── SSL (Let's Encrypt) ────────────────────────────────────────────────────

configure_ssl() {
    echo "==> Requesting SSL certificate for ${DOMAIN}"

    # Stop anything on port 80 temporarily
    local port80_pid=""
    port80_pid=$(lsof -ti:80 2>/dev/null || true)
    if [ -n "${port80_pid}" ]; then
        echo "==> Temporarily stopping service on port 80..."
        kill "${port80_pid}" 2>/dev/null || true
        sleep 3
    fi

    # Wait for port 80 to be free
    local wait_count=0
    while lsof -ti:80 >/dev/null 2>&1; do
        sleep 2
        wait_count=$((wait_count + 1))
        if [ "${wait_count}" -ge 10 ]; then
            echo "WARNING: Port 80 still in use, skipping SSL"
            return 0
        fi
    done

    certbot certonly --standalone \
        -d "${DOMAIN}" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email || {
        echo "WARNING: SSL certificate request failed, continuing without SSL"
        return 0
    }

    # Auto-renewal cron
    local existing_cron=""
    existing_cron=$(crontab -l 2>/dev/null || true)
    if ! echo "${existing_cron}" | grep -q "certbot renew"; then
        (echo "${existing_cron}"; echo "0 3 * * * certbot renew --quiet") | crontab -
    fi

    echo "==> SSL configured with auto-renewal"
    echo "==> NOTE: Configure SSL in Coolify dashboard under Settings > SSL"
}

# ─── Save Credentials ───────────────────────────────────────────────────────

save_credentials() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    local access_url="http://${server_ip}:${COOLIFY_PORT}"
    if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
        access_url="https://${DOMAIN}"
    fi

    cat > "${CREDS_FILE}" <<CREDS
==========================================
  Coolify
  Created: $(date)
==========================================

  Dashboard:
    URL        : ${access_url}
    Alt URL    : http://${server_ip}:${COOLIFY_PORT}
    Port       : ${COOLIFY_PORT}

  IMPORTANT: Create your admin account immediately!
  First person to access the registration page
  gains full control of the server.

  Domain     : ${DOMAIN}
  Server IP  : ${server_ip}

  SSL Cert   : /etc/letsencrypt/live/${DOMAIN}/
  (Configure SSL in Coolify Settings)

  Docker:
    docker ps                   Running containers
    docker compose -f /data/coolify/docker-compose.yml logs -f

  Paths:
    Data Dir   : /data/coolify
    Config     : /data/coolify/.env

==========================================
CREDS

    chmod 600 "${CREDS_FILE}"
    echo "==> Credentials saved to ${CREDS_FILE}"
}

# ─── Welcome Screen (MOTD) ──────────────────────────────────────────────────

setup_motd() {
    echo "==> Setting up SSH welcome screen"

    local motd_script='#!/bin/bash
CREDS_FILE="/root/.coolify-credentials"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    COOLIFY SERVER                           ║"
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
echo "  docker ps                          Running containers"
echo "  docker stats                       Resource usage"
echo "  cd /data/coolify && docker compose logs -f"
echo "  systemctl status coolify           Coolify status"
echo "  certbot certificates               SSL certificate info"
echo ""
'

    # Disable default MOTD scripts
    chmod -x /etc/update-motd.d/* 2>/dev/null || true

    printf '%s' "${motd_script}" > /etc/update-motd.d/99-coolify-info
    chmod +x /etc/update-motd.d/99-coolify-info

    echo "==> MOTD configured"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    detect_os
    wait_for_apt
    check_requirements
    install_dependencies
    install_coolify
    configure_ssl
    save_credentials
    setup_motd

    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo "=========================================="
    echo "  Coolify installed!"
    echo "  Dashboard : http://${server_ip}:${COOLIFY_PORT}"
    echo "  Domain    : https://${DOMAIN}"
    echo "  Creds     : ${CREDS_FILE}"
    echo ""
    echo "  ⚠ Create admin account NOW at:"
    echo "  http://${server_ip}:${COOLIFY_PORT}"
    echo "=========================================="
}

main "$@"
