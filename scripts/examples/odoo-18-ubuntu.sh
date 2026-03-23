#!/bin/bash
#
# Odoo 18 Provisioning Script (Ubuntu 22.04/24.04)
# Installs: Odoo 18 (source) + PostgreSQL 16 + Nginx reverse proxy + SSL (Let's Encrypt)
#
# Required env vars:
#   DOMAIN          - Domain name (e.g. odoo.example.com) — injected by agent
#
# Optional env vars:
#   ODOO_DB_PASS    - PostgreSQL password for odoo user (default: random)
#   ODOO_MASTER     - Odoo master admin password (default: random)
#   ODOO_WORKERS    - Number of workers (default: auto-detect based on CPU)
#
# Supports: Ubuntu 22.04, Ubuntu 24.04

set -euo pipefail

# ─── Force dpkg to keep existing config files (avoid interactive prompts) ────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# ─── Variables ───────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:?DOMAIN env var is required}"
ODOO_DB_PASS="${ODOO_DB_PASS:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)}"
ODOO_MASTER="${ODOO_MASTER:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)}"
ODOO_VERSION="18.0"
ODOO_USER="odoo"
ODOO_HOME="/opt/odoo"
ODOO_CONF="/opt/odoo/config/odoo.conf"
ODOO_LOG="/opt/odoo/logs/odoo.log"
ODOO_PORT="8069"
ODOO_GEVENT_PORT="8072"
CREDS_FILE="/root/.odoo-credentials"

# Auto-detect workers: CPU cores * 2 + 1
CPU_CORES=$(nproc)
ODOO_WORKERS="${ODOO_WORKERS:-$(( CPU_CORES * 2 + 1 ))}"

echo "=========================================="
echo "  Odoo ${ODOO_VERSION} Provisioner"
echo "  Domain  : ${DOMAIN}"
echo "  Workers : ${ODOO_WORKERS}"
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

    if [ "${OS_ID}" != "ubuntu" ]; then
        echo "ERROR: This script only supports Ubuntu 22.04/24.04"
        exit 1
    fi

    echo "==> Detected: ${OS_ID} ${OS_VERSION}"
}

# ─── Install system dependencies ─────────────────────────────────────────────

install_dependencies() {
    # Fix broken dpkg state from prior runs
    dpkg --configure -a --force-confdef --force-confold || true

    echo "==> [APT] Updating packages"
    apt-get update -y

    echo "==> [APT] Installing build dependencies"
    apt-get install "${APT_OPTS[@]}" \
        build-essential \
        python3 python3-venv python3-dev python3-pip \
        libxml2-dev libxslt1-dev libevent-dev libpq-dev \
        libldap2-dev libsasl2-dev libssl-dev libjpeg-dev \
        libfreetype6-dev zlib1g-dev libffi-dev \
        git wget curl \
        nodejs npm \
        nginx certbot python3-certbot-nginx \
        cron

    # Install rtlcss for RTL language support
    npm install -g rtlcss || true

    echo "==> Dependencies installed"
}

# ─── Install PostgreSQL 16 ───────────────────────────────────────────────────

install_postgresql() {
    echo "==> Installing PostgreSQL 16"

    # Add PostgreSQL repo
    if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
        apt-get install "${APT_OPTS[@]}" gnupg2
        sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
        apt-get update -y
    fi

    apt-get install "${APT_OPTS[@]}" postgresql-16

    systemctl enable --now postgresql

    # Create odoo PostgreSQL user
    echo "==> Creating PostgreSQL user 'odoo'"
    su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='odoo'\"" | grep -q 1 || \
        su - postgres -c "psql -c \"CREATE ROLE odoo WITH LOGIN CREATEDB PASSWORD '${ODOO_DB_PASS}'\""

    echo "==> PostgreSQL 16 installed and configured"
}

# ─── Install wkhtmltopdf ─────────────────────────────────────────────────────

install_wkhtmltopdf() {
    echo "==> Installing wkhtmltopdf"

    if command -v wkhtmltopdf &>/dev/null; then
        echo "==> wkhtmltopdf already installed"
        return 0
    fi

    local arch
    arch=$(dpkg --print-architecture)

    local wk_url="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_${arch}.deb"
    wget -q -O /tmp/wkhtmltox.deb "${wk_url}" || {
        echo "WARNING: wkhtmltopdf download failed, trying apt..."
        apt-get install "${APT_OPTS[@]}" wkhtmltopdf || true
        return 0
    }

    apt-get install "${APT_OPTS[@]}" /tmp/wkhtmltox.deb || true
    rm -f /tmp/wkhtmltox.deb

    echo "==> wkhtmltopdf installed"
}

# ─── Create Odoo user & directories ─────────────────────────────────────────

setup_odoo_user() {
    echo "==> Setting up Odoo user and directories"

    if ! id "${ODOO_USER}" &>/dev/null; then
        useradd -m -d "${ODOO_HOME}" -U -r -s /bin/bash "${ODOO_USER}"
    fi

    mkdir -p "${ODOO_HOME}"/{custom-addons,config,logs}
    chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}"

    echo "==> Odoo user and directories ready"
}

# ─── Install Odoo from source ───────────────────────────────────────────────

install_odoo() {
    echo "==> Downloading Odoo ${ODOO_VERSION} source..."

    if [ ! -d "${ODOO_HOME}/odoo/.git" ]; then
        su - "${ODOO_USER}" -c "git clone https://www.github.com/odoo/odoo --depth 1 --branch ${ODOO_VERSION} ${ODOO_HOME}/odoo"
    else
        echo "==> Odoo source already exists, pulling latest..."
        su - "${ODOO_USER}" -c "cd ${ODOO_HOME}/odoo && git pull"
    fi

    echo "==> Setting up Python virtual environment..."
    su - "${ODOO_USER}" -c "python3 -m venv ${ODOO_HOME}/venv"
    su - "${ODOO_USER}" -c "${ODOO_HOME}/venv/bin/pip install --upgrade pip wheel"
    su - "${ODOO_USER}" -c "${ODOO_HOME}/venv/bin/pip install -r ${ODOO_HOME}/odoo/requirements.txt"

    echo "==> Odoo ${ODOO_VERSION} installed"
}

# ─── Odoo config file ───────────────────────────────────────────────────────

configure_odoo() {
    echo "==> Creating Odoo config"

    cat > "${ODOO_CONF}" <<CONF
[options]
; Database
db_host = 127.0.0.1
db_port = 5432
db_user = odoo
db_password = ${ODOO_DB_PASS}
db_name = False
db_maxconn = 64
list_db = False

; Paths
addons_path = ${ODOO_HOME}/odoo/addons,${ODOO_HOME}/custom-addons
data_dir = ${ODOO_HOME}/.local/share/Odoo

; Security
admin_passwd = ${ODOO_MASTER}
proxy_mode = True

; Workers
workers = ${ODOO_WORKERS}
max_cron_threads = 2
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = -1
limit_request = 8192

; Logging
logfile = ${ODOO_LOG}
log_level = warn
log_handler = :WARNING
logrotate = True

; Ports
http_port = ${ODOO_PORT}
gevent_port = ${ODOO_GEVENT_PORT}
xmlrpc_interface = 127.0.0.1
netrpc_interface = 127.0.0.1
CONF

    chown "${ODOO_USER}:${ODOO_USER}" "${ODOO_CONF}"
    chmod 640 "${ODOO_CONF}"

    echo "==> Odoo config created at ${ODOO_CONF}"
}

# ─── Systemd service ────────────────────────────────────────────────────────

setup_systemd() {
    echo "==> Creating Odoo systemd service"

    cat > /etc/systemd/system/odoo.service <<SERVICE
[Unit]
Description=Odoo ${ODOO_VERSION}
Documentation=https://www.odoo.com/documentation/${ODOO_VERSION}/
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=${ODOO_USER}
Group=${ODOO_USER}
ExecStart=${ODOO_HOME}/venv/bin/python3 ${ODOO_HOME}/odoo/odoo-bin \\
    --config=${ODOO_CONF}

Restart=on-failure
RestartSec=5s

LimitNOFILE=65536
LimitNPROC=4096

PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true

StandardOutput=journal
StandardError=journal
SyslogIdentifier=odoo

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable --now odoo

    # Wait for Odoo to start
    echo "==> Waiting for Odoo to start..."
    local retries=0
    while ! curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${ODOO_PORT}" 2>/dev/null | grep -q "200\|303"; do
        sleep 3
        retries=$((retries + 1))
        if [ "${retries}" -ge 20 ]; then
            echo "WARNING: Odoo may not have started yet, continuing..."
            break
        fi
    done

    echo "==> Odoo service started"
}

# ─── Nginx reverse proxy ────────────────────────────────────────────────────

configure_nginx() {
    echo "==> Configuring Nginx reverse proxy"

    cat > "/etc/nginx/sites-available/${DOMAIN}.conf" <<'NGINX'
upstream odoo {
    server 127.0.0.1:ODOO_PORT_PLACEHOLDER;
}

upstream odoo-chat {
    server 127.0.0.1:ODOO_GEVENT_PLACEHOLDER;
}

server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;

    proxy_buffers 16 64k;
    proxy_buffer_size 128k;
    proxy_read_timeout 900s;
    proxy_connect_timeout 900s;
    proxy_send_timeout 900s;

    client_max_body_size 200m;

    gzip on;
    gzip_types text/css text/plain text/xml application/xml application/json application/javascript;
    gzip_min_length 1000;

    location /websocket {
        proxy_pass http://odoo-chat;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://odoo;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }

    location ~* /web/static/ {
        proxy_pass http://odoo;
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 7d;
        add_header Cache-Control "public, no-transform";
    }
}
NGINX

    # Replace placeholders
    sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" "/etc/nginx/sites-available/${DOMAIN}.conf"
    sed -i "s/ODOO_PORT_PLACEHOLDER/${ODOO_PORT}/g" "/etc/nginx/sites-available/${DOMAIN}.conf"
    sed -i "s/ODOO_GEVENT_PLACEHOLDER/${ODOO_GEVENT_PORT}/g" "/etc/nginx/sites-available/${DOMAIN}.conf"

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
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    fi

    echo "==> SSL configured with auto-renewal"
}

# ─── Save Credentials ───────────────────────────────────────────────────────

save_credentials() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    cat > "${CREDS_FILE}" <<CREDS
==========================================
  Odoo ${ODOO_VERSION}
  Created: $(date)
==========================================

  Odoo Web:
    URL            : https://${DOMAIN}
    Master Password: ${ODOO_MASTER}

  Database:
    DB Host        : 127.0.0.1
    DB Port        : 5432
    DB User        : odoo
    DB Password    : ${ODOO_DB_PASS}

  Paths:
    Odoo Home      : ${ODOO_HOME}
    Config         : ${ODOO_CONF}
    Log            : ${ODOO_LOG}
    Custom Addons  : ${ODOO_HOME}/custom-addons
    Data Dir       : ${ODOO_HOME}/.local/share/Odoo

  Service:
    Port (web)     : ${ODOO_PORT}
    Port (gevent)  : ${ODOO_GEVENT_PORT}
    Workers        : ${ODOO_WORKERS}

  Server IP       : ${server_ip}
  Domain          : ${DOMAIN}
==========================================
CREDS

    chmod 600 "${CREDS_FILE}"
    echo "==> Credentials saved to ${CREDS_FILE}"
}

# ─── Welcome Screen (MOTD) ──────────────────────────────────────────────────

setup_motd() {
    echo "==> Setting up SSH welcome screen"

    local motd_script='#!/bin/bash
CREDS_FILE="/root/.odoo-credentials"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    ODOO 18 SERVER                           ║"
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
echo "  systemctl status odoo          Odoo status"
echo "  systemctl restart odoo         Restart Odoo"
echo "  journalctl -u odoo -f          Follow Odoo logs"
echo "  tail -f /opt/odoo/logs/odoo.log"
echo "  su - odoo                      Switch to odoo user"
echo "  psql -U odoo -h 127.0.0.1     Connect to PostgreSQL"
echo "  certbot certificates           SSL certificate info"
echo "  nginx -t && systemctl reload nginx"
echo ""
'

    # Disable default MOTD scripts
    chmod -x /etc/update-motd.d/* 2>/dev/null || true

    printf '%s' "${motd_script}" > /etc/update-motd.d/99-odoo-info
    chmod +x /etc/update-motd.d/99-odoo-info

    echo "==> MOTD configured"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    detect_os
    wait_for_apt
    install_dependencies
    install_postgresql
    install_wkhtmltopdf
    setup_odoo_user
    install_odoo
    configure_odoo
    setup_systemd
    configure_nginx
    configure_ssl
    save_credentials
    setup_motd

    echo ""
    echo "=========================================="
    echo "  Odoo ${ODOO_VERSION} installed!"
    echo "  Website  : https://${DOMAIN}"
    echo "  Master   : ${ODOO_MASTER}"
    echo "  Creds    : ${CREDS_FILE}"
    echo "=========================================="
}

main "$@"
