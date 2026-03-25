#!/bin/bash
#
# Listmonk Provisioning Script
# Installs: Listmonk (newsletter & mailing list manager) via Docker Compose
#           + Nginx reverse proxy + SSL (Let's Encrypt)
#
# Required env vars:
#   DOMAIN          - Domain name (e.g. mail.example.com) — injected by agent
#
# Optional env vars:
#   LISTMONK_ADMIN_USER  - Admin username (default: admin)
#   LISTMONK_ADMIN_PASS  - Admin password (default: random)
#   LISTMONK_DB_PASS     - PostgreSQL password (default: random)
#
# Requirements: 1 CPU core, 1GB RAM, 10GB disk
# Supports: Ubuntu 22/24, Debian 11/12

set -euo pipefail

# ─── Force non-interactive mode ──────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# ─── Variables ───────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:?DOMAIN env var is required}"
LISTMONK_ADMIN_USER="${LISTMONK_ADMIN_USER:-admin}"
LISTMONK_ADMIN_PASS="${LISTMONK_ADMIN_PASS:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)}"
LISTMONK_DB_PASS="${LISTMONK_DB_PASS:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)}"
LISTMONK_PORT="9000"
LISTMONK_DIR="/opt/listmonk"
CREDS_FILE="/root/.listmonk-credentials"

echo "=========================================="
echo "  Listmonk Provisioner"
echo "  Domain : ${DOMAIN}"
echo "  Admin  : ${LISTMONK_ADMIN_USER}"
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

# ─── Install dependencies ───────────────────────────────────────────────────

install_dependencies() {
    # Fix broken dpkg state from prior runs
    dpkg --configure -a --force-confdef --force-confold || true

    echo "==> Installing dependencies..."
    apt-get update -y
    apt-get install "${APT_OPTS[@]}" \
        curl wget ca-certificates gnupg lsb-release \
        nginx certbot python3-certbot-nginx cron

    echo "==> Dependencies installed"
}

# ─── Install Docker ──────────────────────────────────────────────────────────

install_docker() {
    if command -v docker &>/dev/null; then
        echo "==> Docker already installed: $(docker --version)"
        return 0
    fi

    echo "==> Installing Docker..."

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker repo
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -y
    apt-get install "${APT_OPTS[@]}" docker-ce docker-ce-cli containerd.io docker-compose-plugin

    systemctl enable --now docker

    echo "==> Docker installed: $(docker --version)"
}

# ─── Setup Listmonk ─────────────────────────────────────────────────────────

setup_listmonk() {
    echo "==> Setting up Listmonk..."

    mkdir -p "${LISTMONK_DIR}"

    # Create docker-compose.yml
    cat > "${LISTMONK_DIR}/docker-compose.yml" <<COMPOSE
version: "3.7"

services:
  db:
    image: postgres:16-alpine
    container_name: listmonk_db
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: "${LISTMONK_DB_PASS}"
      POSTGRES_USER: listmonk
      POSTGRES_DB: listmonk
    volumes:
      - listmonk-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U listmonk"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - listmonk

  app:
    image: listmonk/listmonk:latest
    container_name: listmonk_app
    restart: unless-stopped
    ports:
      - "127.0.0.1:${LISTMONK_PORT}:9000"
    environment:
      - LISTMONK_app__address=0.0.0.0:9000
      - LISTMONK_app__admin_username=${LISTMONK_ADMIN_USER}
      - LISTMONK_app__admin_password=${LISTMONK_ADMIN_PASS}
      - LISTMONK_db__host=listmonk_db
      - LISTMONK_db__port=5432
      - LISTMONK_db__user=listmonk
      - LISTMONK_db__password=${LISTMONK_DB_PASS}
      - LISTMONK_db__database=listmonk
      - LISTMONK_db__ssl_mode=disable
    depends_on:
      db:
        condition: service_healthy
    networks:
      - listmonk

volumes:
  listmonk-data:

networks:
  listmonk:
COMPOSE

    # Pull images and start
    echo "==> Pulling Docker images..."
    cd "${LISTMONK_DIR}"
    docker compose pull

    # Start only the database first
    echo "==> Starting PostgreSQL..."
    docker compose up -d db

    # Wait for DB to be healthy
    echo "==> Waiting for database to be ready..."
    local db_retries=0
    while ! docker compose exec -T db pg_isready -U listmonk >/dev/null 2>&1; do
        sleep 3
        db_retries=$((db_retries + 1))
        if [ "${db_retries}" -ge 20 ]; then
            echo "ERROR: Database failed to start"
            exit 1
        fi
    done
    echo "==> Database is ready"

    # Initialize database schema (required on first run)
    echo "==> Initializing Listmonk database..."
    docker compose run --rm app ./listmonk --install --yes

    # Start the full stack
    echo "==> Starting Listmonk..."
    docker compose up -d

    # Wait for Listmonk to be ready
    echo "==> Waiting for Listmonk to initialize..."
    local retries=0
    while ! curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${LISTMONK_PORT}" 2>/dev/null | grep -qE "200|302|301"; do
        sleep 5
        retries=$((retries + 1))
        if [ "${retries}" -ge 24 ]; then
            echo "WARNING: Listmonk may not have started yet, continuing..."
            break
        fi
        echo "==> Waiting for Listmonk... (${retries}/24)"
    done

    echo "==> Listmonk is running"
}

# ─── Nginx reverse proxy ────────────────────────────────────────────────────

configure_nginx() {
    echo "==> Configuring Nginx reverse proxy"

    cat > "/etc/nginx/sites-available/${DOMAIN}.conf" <<'NGINX'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:LISTMONK_PORT_PLACEHOLDER;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
    }
}
NGINX

    # Replace placeholders
    sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" "/etc/nginx/sites-available/${DOMAIN}.conf"
    sed -i "s/LISTMONK_PORT_PLACEHOLDER/${LISTMONK_PORT}/g" "/etc/nginx/sites-available/${DOMAIN}.conf"

    # Enable site
    ln -sf "/etc/nginx/sites-available/${DOMAIN}.conf" "/etc/nginx/sites-enabled/"
    rm -f /etc/nginx/sites-enabled/default

    nginx -t && systemctl reload nginx

    echo "==> Nginx configured for ${DOMAIN}"
}

# ─── SSL (Let's Encrypt) ────────────────────────────────────────────────────

configure_ssl() {
    echo "==> Requesting SSL certificate for ${DOMAIN}"

    certbot --nginx \
        -d "${DOMAIN}" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --redirect || {
        echo "WARNING: SSL certificate request failed, continuing without SSL"
        return 0
    }

    # Auto-renewal cron
    local existing_cron=""
    existing_cron=$(crontab -l 2>/dev/null || true)
    if ! echo "${existing_cron}" | grep -q "certbot renew"; then
        (echo "${existing_cron}"; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    fi

    echo "==> SSL configured with auto-renewal"
}

# ─── Save Credentials ───────────────────────────────────────────────────────

save_credentials() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    cat > "${CREDS_FILE}" <<CREDS
==========================================
  Listmonk
  Created: $(date)
==========================================

  Dashboard:
    URL        : https://${DOMAIN}
    Username   : ${LISTMONK_ADMIN_USER}
    Password   : ${LISTMONK_ADMIN_PASS}

  Database (PostgreSQL):
    Host       : listmonk_db (Docker)
    Port       : 5432
    User       : listmonk
    Password   : ${LISTMONK_DB_PASS}
    Database   : listmonk

  Server IP   : ${server_ip}
  Domain      : ${DOMAIN}

  Paths:
    Install Dir : ${LISTMONK_DIR}
    Compose     : ${LISTMONK_DIR}/docker-compose.yml
    DB Data     : Docker volume: listmonk-data

  Docker Commands:
    cd ${LISTMONK_DIR}
    docker compose ps              Status
    docker compose logs -f app     App logs
    docker compose logs -f db      DB logs
    docker compose restart         Restart all
    docker compose pull && docker compose up -d   Update

==========================================
CREDS

    chmod 600 "${CREDS_FILE}"
    echo "==> Credentials saved to ${CREDS_FILE}"
}

# ─── Welcome Screen (MOTD) ──────────────────────────────────────────────────

setup_motd() {
    echo "==> Setting up SSH welcome screen"

    local motd_script='#!/bin/bash
CREDS_FILE="/root/.listmonk-credentials"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    LISTMONK SERVER                          ║"
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
echo "  cd /opt/listmonk && docker compose ps"
echo "  cd /opt/listmonk && docker compose logs -f app"
echo "  cd /opt/listmonk && docker compose restart"
echo "  certbot certificates               SSL info"
echo "  nginx -t && systemctl reload nginx"
echo ""
'

    # Disable default MOTD scripts
    chmod -x /etc/update-motd.d/* 2>/dev/null || true

    printf '%s' "${motd_script}" > /etc/update-motd.d/99-listmonk-info
    chmod +x /etc/update-motd.d/99-listmonk-info

    echo "==> MOTD configured"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    detect_os
    wait_for_apt
    install_dependencies
    install_docker
    setup_listmonk
    configure_nginx
    configure_ssl
    save_credentials
    setup_motd

    echo ""
    echo "=========================================="
    echo "  Listmonk installed!"
    echo "  Dashboard : https://${DOMAIN}"
    echo "  Username  : ${LISTMONK_ADMIN_USER}"
    echo "  Password  : ${LISTMONK_ADMIN_PASS}"
    echo "  Creds     : ${CREDS_FILE}"
    echo "=========================================="
}

main "$@"
