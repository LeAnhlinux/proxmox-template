#!/bin/bash
#
# Vtiger CRM Provisioning Script (Ubuntu 22.04/24.04)
# Installs: Vtiger 8.x + Apache + PHP 8.3 + MariaDB + SSL (Let's Encrypt)
#
# Required env vars:
#   DOMAIN          - Domain name (e.g. crm.example.com) — injected by agent
#
# Optional env vars:
#   DB_NAME         - Database name (default: vtiger)
#   DB_USER         - Database user (default: vtiger_user)
#   DB_PASS         - Database password (default: random)
#
# Supports: Ubuntu 22.04, Ubuntu 24.04

set -euo pipefail

# ─── Force dpkg to keep existing config files (avoid interactive prompts) ────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# ─── Variables ───────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:?DOMAIN env var is required}"
DB_NAME="${DB_NAME:-vtiger}"
DB_USER="${DB_USER:-vtiger_user}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)}"
DB_ROOT_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
VTIGER_VERSION="8.0.0"
WEB_ROOT="/var/www/${DOMAIN}"
CREDS_FILE="/root/.vtiger-credentials"

echo "=========================================="
echo "  Vtiger CRM Provisioner"
echo "  Domain : ${DOMAIN}"
echo "  DB     : ${DB_NAME} / ${DB_USER}"
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

# ─── Install dependencies ───────────────────────────────────────────────────

install_dependencies() {
    # Fix broken dpkg state from prior runs
    dpkg --configure -a --force-confdef --force-confold || true

    echo "==> [APT] Updating packages"
    apt-get update -y

    echo "==> [APT] Installing Apache"
    apt-get install "${APT_OPTS[@]}" apache2

    echo "==> [APT] Installing MariaDB"
    apt-get install "${APT_OPTS[@]}" mariadb-server mariadb-client

    echo "==> [APT] Installing PHP 8.3 and modules"
    apt-get install "${APT_OPTS[@]}" \
        php libapache2-mod-php \
        php-mysql php-curl php-imap php-cli \
        php-gd php-zip php-mbstring php-xml \
        php-intl php-bcmath php-soap php-ldap

    echo "==> [APT] Installing Certbot and cron"
    apt-get install "${APT_OPTS[@]}" certbot python3-certbot-apache cron

    echo "==> Dependencies installed"
}

# ─── Configure MariaDB ──────────────────────────────────────────────────────

configure_database() {
    echo "==> Configuring MariaDB"

    systemctl enable --now mariadb

    # Set root password and secure installation
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';" 2>/dev/null || true

    # Create database and user
    mysql -u root -p"${DB_ROOT_PASS}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

    echo "==> MariaDB configured: database '${DB_NAME}', user '${DB_USER}'"
}

# ─── Configure PHP ──────────────────────────────────────────────────────────

configure_php() {
    echo "==> Configuring PHP"

    # Detect PHP version
    local php_ver
    php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')

    local php_ini="/etc/php/${php_ver}/apache2/php.ini"

    if [ -f "${php_ini}" ]; then
        sed -i 's/^memory_limit = .*/memory_limit = 512M/' "${php_ini}"
        sed -i 's/^max_execution_time = .*/max_execution_time = 120/' "${php_ini}"
        sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 100M/' "${php_ini}"
        sed -i 's/^post_max_size = .*/post_max_size = 100M/' "${php_ini}"
        sed -i 's/^max_input_vars = .*/max_input_vars = 5000/' "${php_ini}"
        sed -i "s/^display_errors = .*/display_errors = Off/" "${php_ini}"
        sed -i "s/^short_open_tag = .*/short_open_tag = Off/" "${php_ini}"
        sed -i "s|^error_reporting = .*|error_reporting = E_ERROR \& ~E_NOTICE \& ~E_STRICT \& ~E_DEPRECATED|" "${php_ini}"
        echo "==> PHP ${php_ver} configured"
    else
        echo "WARNING: php.ini not found at ${php_ini}"
    fi
}

# ─── Download & Install Vtiger ──────────────────────────────────────────────

install_vtiger() {
    echo "==> Downloading Vtiger CRM ${VTIGER_VERSION}..."

    cd /tmp

    # Download Vtiger from SourceForge
    local vtiger_url="https://sourceforge.net/projects/vtigercrm/files/vtiger%20CRM%20${VTIGER_VERSION}/Core%20Product/vtigercrm${VTIGER_VERSION}.tar.gz/download"
    wget -q -O vtigercrm.tar.gz "${vtiger_url}" || {
        echo "==> Trying alternate download URL..."
        wget -q -O vtigercrm.tar.gz "https://sourceforge.net/projects/vtigercrm/files/latest/download" || {
            echo "ERROR: Failed to download Vtiger CRM"
            exit 1
        }
    }

    echo "==> Extracting Vtiger CRM..."
    tar -xzf vtigercrm.tar.gz

    # Move to web root
    mkdir -p "${WEB_ROOT}"
    if [ -d "vtigercrm" ]; then
        cp -a vtigercrm/. "${WEB_ROOT}/"
    elif [ -d "vtigercrm${VTIGER_VERSION}" ]; then
        cp -a "vtigercrm${VTIGER_VERSION}/." "${WEB_ROOT}/"
    else
        # Find extracted directory
        local extracted_dir
        extracted_dir=$(find /tmp -maxdepth 1 -type d -name "vtiger*" | head -1)
        if [ -n "${extracted_dir}" ]; then
            cp -a "${extracted_dir}/." "${WEB_ROOT}/"
        else
            echo "ERROR: Cannot find extracted Vtiger directory"
            exit 1
        fi
    fi

    # Set permissions
    chown -R www-data:www-data "${WEB_ROOT}"
    chmod -R 755 "${WEB_ROOT}"

    # Cleanup
    rm -f /tmp/vtigercrm.tar.gz
    rm -rf /tmp/vtigercrm /tmp/vtigercrm*

    echo "==> Vtiger CRM installed to ${WEB_ROOT}"
}

# ─── Configure Apache ───────────────────────────────────────────────────────

configure_apache() {
    echo "==> Configuring Apache virtual host"

    cat > "/etc/apache2/sites-available/${DOMAIN}.conf" <<VHOST
<VirtualHost *:80>
    ServerAdmin admin@${DOMAIN}
    DocumentRoot ${WEB_ROOT}
    ServerName ${DOMAIN}

    <Directory ${WEB_ROOT}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
VHOST

    # Enable site and required modules
    a2ensite "${DOMAIN}.conf" || true
    a2dissite 000-default.conf 2>/dev/null || true
    a2enmod rewrite || true
    a2enmod ssl || true

    # Test and reload
    apache2ctl configtest
    systemctl enable --now apache2
    systemctl reload apache2

    echo "==> Apache configured for ${DOMAIN}"
}

# ─── SSL (Let's Encrypt) ────────────────────────────────────────────────────

configure_ssl() {
    echo "==> Requesting SSL certificate for ${DOMAIN}"

    certbot --apache \
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
        (echo "${existing_cron}"; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload apache2'") | crontab -
    fi

    echo "==> SSL configured with auto-renewal"
}

# ─── Save Credentials ───────────────────────────────────────────────────────

save_credentials() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    cat > "${CREDS_FILE}" <<CREDS
==========================================
  Vtiger CRM ${VTIGER_VERSION}
  Created: $(date)
==========================================

  Web Access:
    URL            : https://${DOMAIN}
    Setup Wizard   : https://${DOMAIN}/index.php?module=Install&view=Index

  Database:
    DB Name        : ${DB_NAME}
    DB User        : ${DB_USER}
    DB Password    : ${DB_PASS}
    DB Root Pass   : ${DB_ROOT_PASS}
    DB Host        : localhost

  Paths:
    Web Root       : ${WEB_ROOT}
    Apache Config  : /etc/apache2/sites-available/${DOMAIN}.conf

  Server IP       : ${server_ip}
  Domain          : ${DOMAIN}

  First Steps:
    1. Open https://${DOMAIN} in browser
    2. Follow the setup wizard
    3. Enter database credentials above
    4. Create admin account

==========================================
CREDS

    chmod 600 "${CREDS_FILE}"
    echo "==> Credentials saved to ${CREDS_FILE}"
}

# ─── Welcome Screen (MOTD) ──────────────────────────────────────────────────

setup_motd() {
    echo "==> Setting up SSH welcome screen"

    local motd_script='#!/bin/bash
CREDS_FILE="/root/.vtiger-credentials"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   VTIGER CRM SERVER                         ║"
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
echo "  systemctl status apache2        Apache status"
echo "  systemctl restart apache2       Restart Apache"
echo "  systemctl status mariadb        MariaDB status"
echo "  mysql -u root -p                MySQL console"
echo "  certbot certificates            SSL status"
echo "  tail -f /var/log/apache2/*error*"
echo ""
'

    # Disable default MOTD scripts
    chmod -x /etc/update-motd.d/* 2>/dev/null || true

    printf '%s' "${motd_script}" > /etc/update-motd.d/99-vtiger-info
    chmod +x /etc/update-motd.d/99-vtiger-info

    # Fallback: profile.d for non-interactive shells
    printf '%s' "${motd_script}" > /etc/profile.d/vtiger-motd.sh
    chmod +x /etc/profile.d/vtiger-motd.sh

    echo "==> MOTD configured"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    detect_os
    wait_for_apt
    install_dependencies
    configure_database
    configure_php
    install_vtiger
    configure_apache
    configure_ssl
    save_credentials
    setup_motd

    echo ""
    echo "=========================================="
    echo "  Vtiger CRM installed!"
    echo "  Website : https://${DOMAIN}"
    echo "  Wizard  : https://${DOMAIN}/index.php?module=Install&view=Index"
    echo "  Creds   : ${CREDS_FILE}"
    echo "=========================================="
}

main "$@"
