#!/usr/bin/env bash
# Installs Docker Engine + compose plugin if missing (Linux). Needs sudo.
set -euo pipefail
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "Docker already installed: $(docker --version)"
  exit 0
fi
case "$(uname -s)" in
  Linux)
    echo "Installing Docker with the official convenience script..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    sudo systemctl enable --now docker || true
    sudo usermod -aG docker "$USER" || true
    ;;
  Darwin)
    echo "On macOS install Docker Desktop: https://docs.docker.com/desktop/install/mac-install/"
    exit 1 ;;
  *)
    echo "Unsupported OS. Install Docker manually: https://docs.docker.com/engine/install/"
    exit 1 ;;
esac
docker --version || sudo docker --version
