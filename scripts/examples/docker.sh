#!/bin/bash
#
# Template: Docker CE + Docker Compose
# Pulled and executed by proxmox-agent
#
# Env vars (optional):
#   DOCKER_COMPOSE_VERSION - specific compose version (default: latest)

set -euo pipefail

echo "==> Installing Docker CE"

# Prerequisites
apt-get -y update
apt-get -y install ca-certificates curl gnupg jq

# Docker GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Docker repo
ARCH=$(dpkg --print-architecture)
cat > /etc/apt/sources.list.d/docker.list <<EOM
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -c -s) stable
EOM

# Install Docker
apt-get -y update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable Docker
systemctl enable docker
systemctl start docker

# Install standalone Docker Compose (optional, plugin already included)
COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-}"
if [ -z "${COMPOSE_VERSION}" ]; then
  COMPOSE_VERSION=$(curl -sSL "https://api.github.com/repos/docker/compose/releases/latest" | jq -r '.tag_name')
fi

echo "==> Installing Docker Compose ${COMPOSE_VERSION}"
COMPOSE_ARCH=$(uname -m)
mkdir -p ~/.docker/cli-plugins/
curl -SL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" \
  -o ~/.docker/cli-plugins/docker-compose
chmod +x ~/.docker/cli-plugins/docker-compose

# Configure UFW for Docker
sed -e 's|DEFAULT_FORWARD_POLICY=.*|DEFAULT_FORWARD_POLICY="ACCEPT"|g' -i /etc/default/ufw
ufw limit ssh
ufw allow 2375/tcp
ufw allow 2376/tcp
ufw --force enable

# Enable cgroup memory
sed -e 's|GRUB_CMDLINE_LINUX="|GRUB_CMDLINE_LINUX="cgroup_enable=memory swapaccount=1|g' -i /etc/default/grub
update-grub

# Verify
echo "==> Docker version:"
docker --version
echo "==> Docker Compose version:"
docker compose version

echo "==> Docker installation complete!"
