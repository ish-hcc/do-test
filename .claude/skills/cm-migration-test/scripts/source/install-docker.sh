#!/bin/bash
# Docker Engine 설치 (Ubuntu 22.04/24.04). root 로 실행한다.
set -euo pipefail
command -v docker >/dev/null && { docker --version; exit 0; }
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get -y update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
SUDO_USER_NAME=${SUDO_USER:-}
[ -n "$SUDO_USER_NAME" ] && usermod -aG docker "$SUDO_USER_NAME" || true
docker --version
