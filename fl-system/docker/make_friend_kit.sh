#!/usr/bin/env bash
# Run on the SERVER computer. Creates the certificates (if needed) and
# dist/client2-kit.zip with everything your friend needs.
#   bash make_friend_kit.sh <YOUR-IP>          e.g. bash make_friend_kit.sh 192.168.1.23
# Optional: CLIENT_ID=client3 PARTITION_ID=2 bash make_friend_kit.sh <IP>
set -euo pipefail
cd "$(dirname "$0")"
IP=${1:?usage: bash make_friend_kit.sh <your IP address>  (find it with: hostname -I)}
CLIENT_ID=${CLIENT_ID:-client2}
PARTITION_ID=${PARTITION_ID:-1}
PORT=${SUPERLINK_PORT:-9092}

# 1) certificates: (re)create if missing or not valid for this IP
if [[ -f certs/server.pem ]] && openssl x509 -in certs/server.pem -noout -text | grep -q "IP Address:$IP\b"; then
  echo "==> Existing certificates already contain $IP - keeping them"
else
  echo "==> Creating certificates for $IP"
  bash make_certs.sh "$IP"
fi

# 2) assemble the kit
OUT=dist/${CLIENT_ID}-kit
rm -rf "$OUT" "dist/${CLIENT_ID}-kit.zip"; mkdir -p "$OUT"
cp friend-kit/Dockerfile friend-kit/*.sh friend-kit/README.md "$OUT/"
cp -r ../fl-app "$OUT/fl-app"
find "$OUT/fl-app" -name __pycache__ -prune -exec rm -rf {} +
cp ../docker/client/entrypoint.sh "$OUT/entrypoint.sh"
cp certs/ca.crt "$OUT/ca.crt"
cat > "$OUT/client.env" <<ENV
# Filled in by the server owner. Normally nothing to change here.
SUPERLINK_ADDRESS=$IP:$PORT
CLIENT_ID=$CLIENT_ID
PARTITION_ID=$PARTITION_ID
# Optional: full path to a local .csv/.npz dataset. Empty = synthetic data.
DATA_FILE=
ENV
[[ "$CLIENT_ID" == client2 ]] || sed -i "s/client2-kit/${CLIENT_ID}-kit/g; s/fl-client2/fl-${CLIENT_ID}/g; s/client 2/${CLIENT_ID}/g" "$OUT/README.md"
chmod +x "$OUT"/*.sh
(cd dist && zip -qr "${CLIENT_ID}-kit.zip" "${CLIENT_ID}-kit")
echo
echo "==> Done: docker/dist/${CLIENT_ID}-kit.zip  (give this one file to your friend)"
echo "    It contains: client code, Dockerfile, ca.crt, server address $IP:$PORT, scripts, README."
echo "    It does NOT contain any private key."
