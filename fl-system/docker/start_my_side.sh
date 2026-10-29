#!/usr/bin/env bash
# Run on the SERVER computer: starts the server and client 1 here.
#   bash start_my_side.sh <YOUR-IP> [rounds]
set -euo pipefail
cd "$(dirname "$0")"
IP=${1:?usage: bash start_my_side.sh <your IP address> [rounds]}
ROUNDS=${2:-30}
PORT=${SUPERLINK_PORT:-9092}
if docker info >/dev/null 2>&1; then D="docker"; else D="sudo docker"; fi
[[ -f certs/server.pem ]] || { echo "No certificates yet. Run first:  bash make_friend_kit.sh $IP"; exit 1; }
openssl x509 -in certs/server.pem -noout -text | grep -q "IP Address:$IP\b" || {
  echo "Certificates are not for $IP (your IP changed?). Run:  bash make_friend_kit.sh $IP"
  echo "and give your friend the new kit."; exit 1; }

echo "==> Building images (fast after the first time)"
$D build -q -f server/Dockerfile -t fl-server:1.0 .. >/dev/null
$D build -q -f client/Dockerfile -t fl-client:1.0 .. >/dev/null

mkdir -p results
$D rm -f fl-server fl-client1 >/dev/null 2>&1 || true
echo "==> Starting server on port $PORT ($ROUNDS rounds, waits for 2 clients)"
$D run -d --name fl-server -p "$PORT:$PORT" \
  -v "$PWD/certs":/certs:ro -v "$PWD/results":/results \
  -e SUPERLINK_PORT="$PORT" -e NUM_ROUNDS="$ROUNDS" -e NUM_CLIENTS=2 \
  fl-server:1.0 >/dev/null
echo "==> Starting client 1"
$D run -d --name fl-client1 \
  -v "$PWD/certs/ca.crt":/certs/ca.crt:ro \
  -e SUPERLINK_ADDRESS="$IP:$PORT" -e CLIENT_ID=client1 -e PARTITION_ID=0 \
  ${CLIENT1_DATA:+-v "$(dirname "$CLIENT1_DATA")":/data:ro -e DATA_PATH="/data/$(basename "$CLIENT1_DATA")"} \
  fl-client:1.0 >/dev/null
echo
echo "Now ask your friend to run:  bash run_client.sh"
echo "Server log below (Ctrl+C stops watching). Everything stops by itself after the last round."
echo
$D logs -f fl-server || true
CODE=$($D inspect -f '{{.State.ExitCode}}' fl-server 2>/dev/null || echo "?")
timeout 30 $D wait fl-client1 >/dev/null 2>&1 || true
$D rm -f fl-server fl-client1 >/dev/null 2>&1 || true
echo
if [[ "$CODE" == "0" ]]; then
  echo "==> Run finished. Server and client 1 stopped. Results:"
  ls -1t results | head -2 | sed 's|^|    docker/results/|'
else
  echo "==> The run failed (exit code $CODE) - see the log above."
fi
