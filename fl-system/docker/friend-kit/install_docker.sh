#!/usr/bin/env bash
# Installs Docker inside Ubuntu (also inside WSL). Run once:  bash install_docker.sh
set -euo pipefail
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker (needs internet and your Ubuntu password)"
  sudo apt-get update
  sudo apt-get install -y curl ca-certificates
  curl -fsSL https://get.docker.com | sudo sh
else
  echo "==> Docker is already installed: $(docker --version)"
fi
echo "==> Allowing user $USER to use Docker"
getent group docker >/dev/null || sudo groupadd docker
sudo usermod -aG docker "$USER"
echo "==> Starting Docker"
sudo service docker start >/dev/null 2>&1 || sudo systemctl start docker || true
sleep 2
if sudo docker run --rm hello-world >/dev/null 2>&1; then
  echo
  echo "Docker works.  Next:  bash run_client.sh"
  echo "(run_client.sh uses sudo by itself if needed, so no restart is required)"
else
  echo "Docker did not start. Try:  sudo service docker start   then run this script again."
  exit 1
fi
