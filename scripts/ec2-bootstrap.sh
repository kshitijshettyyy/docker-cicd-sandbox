#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# EC2 Bootstrap Script
# Run once on a fresh Amazon Linux 2 / Ubuntu 22.04 EC2 instance.
#
# Usage:
#   chmod +x ec2-bootstrap.sh
#   sudo ./ec2-bootstrap.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

echo "==> Detecting OS..."
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  echo "Cannot detect OS. Exiting." && exit 1
fi

install_docker_amazon() {
  echo "==> Installing Docker on Amazon Linux 2..."
  yum update -y
  yum install -y docker
  systemctl enable --now docker
  usermod -aG docker ec2-user
}

install_docker_ubuntu() {
  echo "==> Installing Docker on Ubuntu..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io
  systemctl enable --now docker
  usermod -aG docker ubuntu
}

case "$OS" in
  amzn)   install_docker_amazon ;;
  ubuntu) install_docker_ubuntu ;;
  *)      echo "Unsupported OS: $OS" && exit 1 ;;
esac

echo ""
echo "✅  Docker installed successfully."
echo "    Log out and back in (or run 'newgrp docker') so your user can run docker without sudo."
echo "    Then add the following GitHub Actions secrets to your repo:"
echo "      EC2_HOST     → $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo '<your-ec2-public-ip>')"
echo "      EC2_USER     → ec2-user  (Amazon Linux) or ubuntu (Ubuntu)"
echo "      EC2_SSH_KEY  → contents of your .pem private key"
echo "      DOCKERHUB_USERNAME → your Docker Hub username"
echo "      DOCKERHUB_TOKEN    → a Docker Hub access token (not your password)"
