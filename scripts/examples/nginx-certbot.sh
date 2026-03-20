#!/bin/bash
#
# Template: Nginx + Certbot (Let's Encrypt)
#
# Env vars (optional):
#   DOMAIN - domain name for SSL cert

set -euo pipefail

echo "==> Installing Nginx + Certbot"

apt-get -y update
apt-get -y install nginx certbot python3-certbot-nginx

# Enable Nginx
systemctl enable nginx
systemctl start nginx

# Configure UFW
ufw limit ssh
ufw allow 'Nginx Full'
ufw --force enable

# Setup SSL if domain is provided
if [ -n "${DOMAIN:-}" ]; then
  echo "==> Requesting SSL cert for ${DOMAIN}"
  certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email || true
fi

echo "==> Nginx installation complete!"
nginx -v
