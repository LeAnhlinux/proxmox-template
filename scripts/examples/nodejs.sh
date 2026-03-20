#!/bin/bash
#
# Template: Node.js + PM2
#
# Env vars (optional):
#   NODE_VERSION - major version to install (default: 22)

set -euo pipefail

NODE_VERSION="${NODE_VERSION:-22}"

echo "==> Installing Node.js ${NODE_VERSION}"

# Install via NodeSource
apt-get -y update
apt-get -y install ca-certificates curl gnupg

mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

cat > /etc/apt/sources.list.d/nodesource.list <<EOM
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main
EOM

apt-get -y update
apt-get -y install nodejs

# Install PM2 globally
npm install -g pm2
pm2 startup systemd -u root --hp /root

# Configure UFW
ufw limit ssh
ufw allow http
ufw allow https
ufw --force enable

echo "==> Node.js installation complete!"
node --version
npm --version
pm2 --version
