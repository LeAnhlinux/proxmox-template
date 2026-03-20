#!/bin/bash
#
# WordPress Provisioning Script
# Installs: Nginx + PHP 8.4 + MariaDB + WordPress + SSL (Let's Encrypt)
#
# Required env vars:
#   DOMAIN          - Domain name (e.g. app.example.com) — injected by agent
#
# Optional env vars:
#   DB_NAME         - Database name (default: wordpress)
#   DB_USER         - Database user (default: wp_user)
#   WP_LOCALE       - WordPress locale (default: en_US)
#
# Supports: Ubuntu 22/24, AlmaLinux 8/9, Rocky Linux 8/9

set -euo pipefail

# ─── Variables ───────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:?DOMAIN env var is required}"
DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-wp_user}"
DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
WP_LOCALE="${WP_LOCALE:-en_US}"
WEB_ROOT="/var/www/${DOMAIN}"
CREDS_FILE="/root/.wp-credentials"

echo "=========================================="
echo "  WordPress Provisioner"
echo "  Domain : ${DOMAIN}"
echo "  DB     : ${DB_NAME} / ${DB_USER}"
echo "=========================================="

# ─── Wait for apt/dnf lock ───────────────────────────────────────────────────

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
            echo "    apt is locked, waiting... (${waited}s)"
            sleep 5
            waited=$((waited + 5))
        done
    elif command -v dnf &>/dev/null; then
        echo "==> Waiting for dnf lock to be released..."
        while fuser /var/run/dnf.pid &>/dev/null 2>&1; do
            if [ "${waited}" -ge "${max_wait}" ]; then
                echo "ERROR: Timed out waiting for dnf lock after ${max_wait}s"
                exit 1
            fi
            echo "    dnf is locked, waiting... (${waited}s)"
            sleep 5
            waited=$((waited + 5))
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
        OS_VERSION="${VERSION_ID%%.*}"
    else
        echo "ERROR: Cannot detect OS"
        exit 1
    fi

    case "${OS_ID}" in
        ubuntu|debian)
            PKG_MANAGER="apt"
            ;;
        almalinux|rocky|centos|rhel)
            PKG_MANAGER="dnf"
            ;;
        *)
            echo "ERROR: Unsupported OS: ${OS_ID}"
            exit 1
            ;;
    esac

    echo "==> Detected: ${OS_ID} ${VERSION_ID} (${PKG_MANAGER})"
}

# ─── Install on Debian/Ubuntu ────────────────────────────────────────────────

install_apt() {
    echo "==> [APT] Updating packages"
    apt-get update -y

    # Add PHP 8.4 PPA (ondrej)
    echo "==> [APT] Adding PHP 8.4 repository"
    apt-get install -y software-properties-common curl gnupg2
    add-apt-repository -y ppa:ondrej/php
    apt-get update -y

    # Install Nginx
    echo "==> [APT] Installing Nginx"
    apt-get install -y nginx

    # Install MariaDB
    echo "==> [APT] Installing MariaDB"
    apt-get install -y mariadb-server mariadb-client

    # Install PHP 8.4
    echo "==> [APT] Installing PHP 8.4"
    apt-get install -y \
        php8.4-fpm \
        php8.4-mysql \
        php8.4-curl \
        php8.4-gd \
        php8.4-intl \
        php8.4-mbstring \
        php8.4-xml \
        php8.4-zip \
        php8.4-bcmath \
        php8.4-imagick \
        php8.4-redis \
        php8.4-opcache

    # Install Certbot
    echo "==> [APT] Installing Certbot"
    apt-get install -y certbot python3-certbot-nginx

    # Install WP-CLI
    echo "==> [APT] Installing WP-CLI"
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp

    PHP_FPM_SOCK="/run/php/php8.4-fpm.sock"
    PHP_FPM_SERVICE="php8.4-fpm"
}

# ─── Install on RHEL/AlmaLinux/Rocky ─────────────────────────────────────────

install_dnf() {
    echo "==> [DNF] Updating packages"
    dnf update -y

    # Install EPEL + Remi repo for PHP 8.4
    echo "==> [DNF] Adding EPEL and Remi repositories"
    dnf install -y epel-release
    dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-${OS_VERSION}.rpm" || true
    dnf module reset php -y 2>/dev/null || true
    dnf module enable php:remi-8.4 -y 2>/dev/null || true

    # Install Nginx
    echo "==> [DNF] Installing Nginx"
    dnf install -y nginx

    # Install MariaDB
    echo "==> [DNF] Installing MariaDB"
    dnf install -y mariadb-server

    # Install PHP 8.4
    echo "==> [DNF] Installing PHP 8.4"
    dnf install -y \
        php-fpm \
        php-mysqlnd \
        php-curl \
        php-gd \
        php-intl \
        php-mbstring \
        php-xml \
        php-zip \
        php-bcmath \
        php-imagick \
        php-redis \
        php-opcache \
        php-json

    # Install Certbot
    echo "==> [DNF] Installing Certbot"
    dnf install -y certbot python3-certbot-nginx

    # Install WP-CLI
    echo "==> [DNF] Installing WP-CLI"
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp

    PHP_FPM_SOCK="/run/php-fpm/www.sock"
    PHP_FPM_SERVICE="php-fpm"

    # SELinux: allow nginx to connect to php-fpm and network
    if command -v setsebool &>/dev/null; then
        echo "==> [DNF] Configuring SELinux for Nginx"
        setsebool -P httpd_can_network_connect 1
        setsebool -P httpd_execmem 1
        setsebool -P httpd_unified 1
    fi
}

# ─── Configure MariaDB ──────────────────────────────────────────────────────

configure_mariadb() {
    echo "==> Configuring MariaDB"

    systemctl enable --now mariadb

    # Secure MariaDB (non-interactive)
    mysql -e "DELETE FROM mysql.user WHERE User='';"
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mysql -e "DROP DATABASE IF EXISTS test;"
    mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"

    # Create WordPress database and user
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    echo "==> MariaDB configured: ${DB_NAME} / ${DB_USER}"
}

# ─── Configure PHP-FPM ──────────────────────────────────────────────────────

configure_php_fpm() {
    echo "==> Configuring PHP-FPM"

    # Optimize php.ini for WordPress
    PHP_INI=""
    if [ "${PKG_MANAGER}" = "apt" ]; then
        PHP_INI="/etc/php/8.4/fpm/php.ini"
    else
        PHP_INI="/etc/php.ini"
    fi

    if [ -f "${PHP_INI}" ]; then
        sed -i 's/upload_max_filesize = .*/upload_max_filesize = 64M/' "${PHP_INI}"
        sed -i 's/post_max_size = .*/post_max_size = 64M/' "${PHP_INI}"
        sed -i 's/memory_limit = .*/memory_limit = 256M/' "${PHP_INI}"
        sed -i 's/max_execution_time = .*/max_execution_time = 300/' "${PHP_INI}"
        sed -i 's/max_input_vars = .*/max_input_vars = 3000/' "${PHP_INI}"
    fi

    # Ensure PHP-FPM listens on unix socket
    if [ "${PKG_MANAGER}" = "dnf" ]; then
        WWW_CONF="/etc/php-fpm.d/www.conf"
        if [ -f "${WWW_CONF}" ]; then
            sed -i 's/^user = .*/user = nginx/' "${WWW_CONF}"
            sed -i 's/^group = .*/group = nginx/' "${WWW_CONF}"
            sed -i "s|^listen = .*|listen = ${PHP_FPM_SOCK}|" "${WWW_CONF}"
            sed -i 's/^listen.owner = .*/listen.owner = nginx/' "${WWW_CONF}"
            sed -i 's/^listen.group = .*/listen.group = nginx/' "${WWW_CONF}"
        fi
    fi

    systemctl enable --now "${PHP_FPM_SERVICE}"
    echo "==> PHP-FPM started: ${PHP_FPM_SOCK}"
}

# ─── Install WordPress ──────────────────────────────────────────────────────

install_wordpress() {
    echo "==> Installing WordPress"

    mkdir -p "${WEB_ROOT}"

    # Download WordPress
    wp core download \
        --path="${WEB_ROOT}" \
        --locale="${WP_LOCALE}" \
        --allow-root

    # Generate wp-config.php
    wp config create \
        --path="${WEB_ROOT}" \
        --dbname="${DB_NAME}" \
        --dbuser="${DB_USER}" \
        --dbpass="${DB_PASS}" \
        --dbhost="localhost" \
        --dbcharset="utf8mb4" \
        --allow-root

    # Set correct ownership
    if [ "${PKG_MANAGER}" = "apt" ]; then
        chown -R www-data:www-data "${WEB_ROOT}"
    else
        chown -R nginx:nginx "${WEB_ROOT}"
    fi

    chmod -R 755 "${WEB_ROOT}"

    echo "==> WordPress downloaded to ${WEB_ROOT}"
}

# ─── Configure Nginx ────────────────────────────────────────────────────────

configure_nginx() {
    echo "==> Configuring Nginx for ${DOMAIN}"

    # Remove default site
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

    # Determine config path
    if [ "${PKG_MANAGER}" = "apt" ]; then
        NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"
        NGINX_LINK="/etc/nginx/sites-enabled/${DOMAIN}.conf"
        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

        # Ensure sites-enabled is included
        if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
            sed -i '/http {/a \    include /etc/nginx/sites-enabled/*.conf;' /etc/nginx/nginx.conf
        fi
    else
        NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
    fi

    cat > "${NGINX_CONF}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEB_ROOT};
    index index.php index.html;

    client_max_body_size 64M;

    # WordPress permalinks
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # PHP-FPM
    location ~ \.php\$ {
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    # Deny access to hidden files
    location ~ /\. {
        deny all;
    }

    # Deny access to wp-config.php
    location = /wp-config.php {
        deny all;
    }

    # Static file caching
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
NGINX

    # Create symlink for Debian/Ubuntu
    if [ "${PKG_MANAGER}" = "apt" ]; then
        ln -sf "${NGINX_CONF}" "${NGINX_LINK}"
    fi

    # Test and start Nginx
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx

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
        --redirect

    # Auto-renewal cron
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    fi

    echo "==> SSL configured with auto-renewal"
}

# ─── Firewall ────────────────────────────────────────────────────────────────

configure_firewall() {
    echo "==> Configuring firewall"

    if [ "${PKG_MANAGER}" = "apt" ]; then
        if command -v ufw &>/dev/null; then
            ufw allow 'Nginx Full' || ufw allow 80/tcp && ufw allow 443/tcp
            ufw --force enable
            echo "==> UFW: HTTP/HTTPS allowed"
        fi
    else
        if command -v firewall-cmd &>/dev/null; then
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
            firewall-cmd --reload
            echo "==> firewalld: HTTP/HTTPS allowed"
        fi
    fi
}

# ─── Save Credentials ───────────────────────────────────────────────────────

save_credentials() {
    cat > "${CREDS_FILE}" <<CREDS
==========================================
  WordPress Credentials
  Created: $(date)
==========================================

Domain   : https://${DOMAIN}
WP Admin : https://${DOMAIN}/wp-admin

Database : ${DB_NAME}
DB User  : ${DB_USER}
DB Pass  : ${DB_PASS}
DB Host  : localhost

Web Root : ${WEB_ROOT}
==========================================
CREDS

    chmod 600 "${CREDS_FILE}"
    echo "==> Credentials saved to ${CREDS_FILE}"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    detect_os
    wait_for_package_manager

    if [ "${PKG_MANAGER}" = "apt" ]; then
        install_apt
    else
        install_dnf
    fi

    configure_mariadb
    configure_php_fpm
    install_wordpress
    configure_nginx
    configure_ssl
    configure_firewall
    save_credentials

    echo ""
    echo "=========================================="
    echo "  WordPress installed successfully!"
    echo "  URL     : https://${DOMAIN}"
    echo "  WP Admin: https://${DOMAIN}/wp-admin"
    echo "  Creds   : ${CREDS_FILE}"
    echo "=========================================="
}

main
