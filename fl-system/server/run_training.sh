#!/usr/bin/env bash
# Submits the Flower App to the SuperLink over TLS and streams the logs.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env
CA="$(pwd)/certs/ca.crt"
CFG="$HOME/.flwr/config.toml"
mkdir -p "$(dirname "$CFG")"
[[ -f "$CFG" ]] || printf '[superlink]\ndefault = "fl-server"\n' > "$CFG"
if ! grep -q '^\[superlink.fl-server\]' "$CFG"; then
  cat >> "$CFG" <<TOML

[superlink.fl-server]
address = "$SERVER_IP:$SUPERLINK_PORT"
root-certificates = "$CA"
TOML
fi
echo "==> flwr run ../fl-app fl-server --stream $*"
flwr run ../fl-app fl-server --stream "$@"
