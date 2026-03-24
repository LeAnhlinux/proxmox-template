#!/bin/bash
#
# OpenLiteSpeed + WordPress Provisioning Script
# Installs: OpenLiteSpeed + LSPHP 8.4 + MariaDB + WordPress + LiteSpeed Cache + SSL
#
# Uses official ols1clk.sh installer from LiteSpeed Technologies
# Reference: https://github.com/litespeedtech/ols1clk
#
# Required env vars:
#   DOMAIN          - Domain name (e.g. app.example.com) — injected by agent
#
# Optional env vars:
#   DB_NAME         - Database name (default: wordpress)
#   DB_USER         - Database user (default: wp_user)
#   WP_ADMIN_USER   - WordPress admin username (default: admin)
#   WP_ADMIN_EMAIL  - WordPress admin email (default: admin@DOMAIN)
#   LSPHP_VERSION   - LSPHP version (default: 84)
#
# Supports: Ubuntu 20/22/24, Debian 10/11/12, AlmaLinux 8/9, Rocky 8/9

set -euo pipefail

# ─── Force non-interactive mode ─────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# ─── Variables ───────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:?DOMAIN env var is required}"
DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-wp_user}"
DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
DB_ROOT_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
WP_ADMIN_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@${DOMAIN}}"
LSPHP_VERSION="${LSPHP_VERSION:-84}"
OLS_ADMIN_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)
CREDS_FILE="/root/.ols-wp-credentials"
SERVER_ROOT="/usr/local/lsws"

echo "=========================================="
echo "  OpenLiteSpeed + WordPress Provisioner"
echo "  Domain : ${DOMAIN}"
echo "  DB     : ${DB_NAME} / ${DB_USER}"
echo "  LSPHP  : ${LSPHP_VERSION}"
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

# ─── Pre-install dependencies ────────────────────────────────────────────────

install_dependencies() {
    echo "==> Installing dependencies..."

    if [ "${PKG_MANAGER}" = "apt" ]; then
        dpkg --configure -a --force-confdef --force-confold || true
        apt-get update -y
        apt-get install "${APT_OPTS[@]}" curl wget cron certbot
    else
        dnf install -y curl wget cronie certbot
        systemctl enable --now crond
    fi

    echo "==> Dependencies installed"
}

# ─── Install OpenLiteSpeed + WordPress via ols1clk.sh ────────────────────────

install_ols_wordpress() {
    echo "==> Downloading ols1clk.sh installer..."
    cd /tmp

    curl -fsSL -o ols1clk.sh https://raw.githubusercontent.com/litespeedtech/ols1clk/master/ols1clk.sh || {
        echo "ERROR: Failed to download ols1clk.sh"
        exit 1
    }
    chmod +x ols1clk.sh

    echo "==> Running OpenLiteSpeed + WordPress installer..."
    echo "    --wordpressplus ${DOMAIN}"
    echo "    --lsphp ${LSPHP_VERSION}"
    echo "    --dbname ${DB_NAME}"
    echo "    --dbuser ${DB_USER}"

    # ols1clk.sh --wordpressplus: full auto WordPress install with domain
    # -Q: quiet mode, no prompts
    bash ols1clk.sh \
        -Q \
        --wordpressplus "${DOMAIN}" \
        --lsphp "${LSPHP_VERSION}" \
        -A "${OLS_ADMIN_PASS}" \
        -E "${WP_ADMIN_EMAIL}" \
        -R "${DB_ROOT_PASS}" \
        --dbname "${DB_NAME}" \
        --dbuser "${DB_USER}" \
        --dbpassword "${DB_PASS}" \
        --wpuser "${WP_ADMIN_USER}" \
        --wppassword "${WP_ADMIN_PASS}" || {
        echo "ERROR: OpenLiteSpeed installation failed"
        exit 1
    }

    # Verify OLS is running (service name: lsws or lshttpd)
    sleep 5
    OLS_SERVICE=""
    if systemctl is-active --quiet lsws 2>/dev/null; then
        OLS_SERVICE="lsws"
    elif systemctl is-active --quiet lshttpd 2>/dev/null; then
        OLS_SERVICE="lshttpd"
    elif [ -x "${SERVER_ROOT}/bin/lswsctrl" ]; then
        # Try starting via lswsctrl directly
        "${SERVER_ROOT}/bin/lswsctrl" start || true
        sleep 3
        OLS_SERVICE="lsws"
    fi

    if [ -n "${OLS_SERVICE}" ]; then
        echo "==> OpenLiteSpeed is running (service: ${OLS_SERVICE})"
    else
        echo "==> WARNING: Could not verify OpenLiteSpeed service status"
        # Try direct start as fallback
        "${SERVER_ROOT}/bin/lswsctrl" start 2>/dev/null || true
    fi

    echo "==> OpenLiteSpeed + WordPress installation completed"
}

# ─── SSL (Let's Encrypt via certbot) ────────────────────────────────────────

configure_ssl() {
    echo "==> Requesting SSL certificate for ${DOMAIN}"

    # Stop OLS temporarily so certbot can bind port 80
    "${SERVER_ROOT}/bin/lswsctrl" stop 2>/dev/null || systemctl stop lsws 2>/dev/null || true

    # Wait for port 80 to be fully released
    echo "==> Waiting for port 80 to be released..."
    local wait_port=0
    while ss -tlnp | grep -q ':80 ' && [ "${wait_port}" -lt 30 ]; do
        sleep 2
        wait_port=$((wait_port + 2))
    done

    # Try certbot with retry
    local ssl_ok=false
    for attempt in 1 2 3; do
        echo "==> Certbot attempt ${attempt}/3..."
        if certbot certonly \
            --standalone \
            -d "${DOMAIN}" \
            --non-interactive \
            --agree-tos \
            --register-unsafely-without-email; then
            ssl_ok=true
            break
        fi
        echo "==> Attempt ${attempt} failed, waiting 10s before retry..."
        sleep 10
    done

    if [ "${ssl_ok}" = false ]; then
        echo "WARNING: SSL certificate request failed after 3 attempts, continuing without SSL"
        "${SERVER_ROOT}/bin/lswsctrl" start 2>/dev/null || systemctl start lsws 2>/dev/null || true
        return 0
    fi

    # Replace self-signed cert with Let's Encrypt in existing wordpressssl listener
    local cert_path="/etc/letsencrypt/live/${DOMAIN}"
    local httpd_conf="${SERVER_ROOT}/conf/httpd_config.conf"

    if [ -f "${httpd_conf}" ]; then
        # Update keyFile and certFile in the wordpressssl listener (created by ols1clk.sh)
        sed -i "s|keyFile.*example\.key|keyFile                 ${cert_path}/privkey.pem|" "${httpd_conf}"
        sed -i "s|certFile.*example\.crt|certFile                ${cert_path}/fullchain.pem|" "${httpd_conf}"
        echo "==> Updated wordpressssl listener with Let's Encrypt certs"
    fi

    # Start OLS back
    "${SERVER_ROOT}/bin/lswsctrl" start 2>/dev/null || systemctl start lsws 2>/dev/null || true

    # Auto-renewal cron with OLS restart
    local existing_cron=""
    existing_cron=$(crontab -l 2>/dev/null || true)
    if ! echo "${existing_cron}" | grep -q "certbot renew"; then
        echo "${existing_cron}
0 3 * * * certbot renew --quiet --pre-hook '${SERVER_ROOT}/bin/lswsctrl stop' --post-hook '${SERVER_ROOT}/bin/lswsctrl start'" | crontab - || true
    fi

    echo "==> SSL configured with auto-renewal"
}

# ─── Fix WordPress URL (cookies/redirect issue) ─────────────────────────────

fix_wordpress_url() {
    echo "==> Fixing WordPress site URL to use domain..."

    local wp_path="${SERVER_ROOT}/wordpress"
    local site_url="https://${DOMAIN}"

    # Check if SSL cert exists, use http if not
    if [ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
        site_url="http://${DOMAIN}"
    fi

    # Update WordPress siteurl and home via WP-CLI
    if command -v wp &>/dev/null && [ -f "${wp_path}/wp-config.php" ]; then
        wp option update siteurl "${site_url}" --path="${wp_path}" --allow-root || true
        wp option update home "${site_url}" --path="${wp_path}" --allow-root || true
        echo "==> WordPress URL set to ${site_url}"
    else
        # Fallback: update via MySQL directly
        local db_name db_prefix
        db_name=$(grep "DB_NAME" "${wp_path}/wp-config.php" | cut -d"'" -f4 2>/dev/null || echo "${DB_NAME}")
        db_prefix=$(grep "table_prefix" "${wp_path}/wp-config.php" | cut -d"'" -f2 2>/dev/null || echo "wp_")
        mysql -e "UPDATE ${db_name}.${db_prefix}options SET option_value='${site_url}' WHERE option_name IN ('siteurl','home');" || true
        echo "==> WordPress URL set to ${site_url} (via MySQL)"
    fi
}

# ─── Save Credentials ───────────────────────────────────────────────────────

save_credentials() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    cat > "${CREDS_FILE}" <<CREDS
==========================================
  OpenLiteSpeed + WordPress
  Created: $(date)
==========================================

  Website:
    URL        : https://${DOMAIN}
    WP Admin   : https://${DOMAIN}/wp-admin
    WP User    : ${WP_ADMIN_USER}
    WP Password: ${WP_ADMIN_PASS}
    WP Email   : ${WP_ADMIN_EMAIL}

  OpenLiteSpeed WebAdmin:
    URL        : https://${server_ip}:7080
    Username   : admin
    Password   : ${OLS_ADMIN_PASS}

  Database:
    DB Name    : ${DB_NAME}
    DB User    : ${DB_USER}
    DB Password: ${DB_PASS}
    DB Root    : ${DB_ROOT_PASS}
    DB Host    : localhost

  Paths:
    Web Root   : ${SERVER_ROOT}/wordpress
    OLS Config : ${SERVER_ROOT}/conf/httpd_config.conf
    VHost Conf : ${SERVER_ROOT}/conf/vhosts/${DOMAIN}/

  Server IP  : ${server_ip}
==========================================
CREDS

    chmod 600 "${CREDS_FILE}"
    echo "==> Credentials saved to ${CREDS_FILE}"
}

# ─── Welcome Screen (MOTD) ──────────────────────────────────────────────────

setup_motd() {
    echo "==> Setting up SSH welcome screen"

    local motd_script='#!/bin/bash
CREDS_FILE="/root/.ols-wp-credentials"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║            OPENLITESPEED + WORDPRESS SERVER                 ║"
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
echo "  /usr/local/lsws/bin/lswsctrl restart   Restart OLS"
echo "  /usr/local/lsws/bin/lswsctrl status    OLS status"
echo "  wp --path=/usr/local/lsws/wordpress/ --allow-root"
echo "  certbot certificates                   SSL status"
echo "  cat /root/.ols-wp-credentials          View credentials"
echo ""
'

    # Method 1: update-motd.d (Ubuntu/Debian)
    if [ -d /etc/update-motd.d ]; then
        chmod -x /etc/update-motd.d/* 2>/dev/null || true
        echo "${motd_script}" > /etc/update-motd.d/99-app-info
        chmod +x /etc/update-motd.d/99-app-info
    fi

    # Method 2: profile.d (always works on SSH login)
    echo "${motd_script}" > /etc/profile.d/99-app-info.sh
    chmod +x /etc/profile.d/99-app-info.sh

    # Disable default MOTD to avoid duplicate
    [ -f /etc/default/motd-news ] && sed -i 's/ENABLED=1/ENABLED=0/' /etc/default/motd-news 2>/dev/null || true

    echo "==> MOTD configured"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    detect_os
    wait_for_package_manager
    install_dependencies
    install_ols_wordpress
    configure_ssl
    fix_wordpress_url
    save_credentials
    setup_motd

    echo ""
    echo "=========================================="
    echo "  OpenLiteSpeed + WordPress installed!"
    echo "  Website  : https://${DOMAIN}"
    echo "  WP Admin : https://${DOMAIN}/wp-admin"
    echo "  OLS Admin: https://$(hostname -I | awk '{print $1}'):7080"
    echo "  Creds    : ${CREDS_FILE}"
    echo "=========================================="
}

main
