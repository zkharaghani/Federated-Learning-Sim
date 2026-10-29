#!/usr/bin/env bash
# Starts FL client 2.   bash run_client.sh
# Settings are in client.env (filled in by the person running the server).
set -euo pipefail
cd "$(dirname "$0")"
source ./client.env
IMAGE=fl-client:1.0
NAME=fl-${CLIENT_ID}

# --- Docker: start it if needed, use sudo if this user isn't in the docker group
command -v docker >/dev/null || { echo "Docker is not installed. Run:  bash install_docker.sh"; exit 1; }
if ! docker info >/dev/null 2>&1 && ! sudo docker info >/dev/null 2>&1; then
  echo "==> Starting Docker"; sudo service docker start >/dev/null 2>&1 || sudo systemctl start docker || true; sleep 3
fi
if docker info >/dev/null 2>&1; then D="docker"; else D="sudo docker"; fi
$D info >/dev/null 2>&1 || { echo "Docker is not running. Try:  sudo service docker start"; exit 1; }

[[ -f ca.crt ]] || { echo "ca.crt is missing from this folder - ask the server owner for it."; exit 1; }

# --- Build the image (a few minutes the first time; seconds afterwards thanks to
#     Docker's cache). Always rebuilding means a new kit never runs with an old image.
if $D image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> Checking the client image is up to date"
  $D build -q -t "$IMAGE" . >/dev/null
else
  echo "==> Building the client image (first time only, a few minutes)"
  $D build -t "$IMAGE" .
fi

# --- Optional local dataset
DATA_ARGS=()
if [[ -n "${DATA_FILE:-}" ]]; then
  [[ -f "$DATA_FILE" ]] || { echo "DATA_FILE=$DATA_FILE does not exist"; exit 1; }
  DATA_ARGS=(-v "$(cd "$(dirname "$DATA_FILE")" && pwd)":/data:ro -e DATA_PATH="/data/$(basename "$DATA_FILE")")
  echo "==> Using local dataset $DATA_FILE (read-only, never leaves this computer)"
else
  echo "==> No DATA_FILE set: using synthetic data"
fi

# --- Can we reach the server?
HOST=${SUPERLINK_ADDRESS%:*}; PORT=${SUPERLINK_ADDRESS##*:}
if timeout 5 bash -c "exec 3<>/dev/tcp/$HOST/$PORT" 2>/dev/null; then
  echo "==> Server $SUPERLINK_ADDRESS is reachable"
else
  echo "WARNING: cannot reach $SUPERLINK_ADDRESS right now."
  echo "         Is the server running? Same network? (Guest/eduroam Wi-Fi often blocks this; try a phone hotspot.)"
  echo "         The client starts anyway and keeps retrying."
fi

# --- Start
$D rm -f "$NAME" >/dev/null 2>&1 || true
$D run -d --name "$NAME" \
  -v "$PWD/ca.crt":/certs/ca.crt:ro \
  -e SUPERLINK_ADDRESS="$SUPERLINK_ADDRESS" \
  -e CLIENT_ID="$CLIENT_ID" -e PARTITION_ID="$PARTITION_ID" -e NUM_PARTITIONS=2 \
  "${DATA_ARGS[@]}" \
  "$IMAGE" >/dev/null
echo "==> Client $CLIENT_ID started. Showing its log (Ctrl+C stops watching, not the client)."
echo "    It stops by itself when the server says training is finished."
echo
$D logs -f "$NAME" || true
CODE=$($D inspect -f '{{.State.ExitCode}}' "$NAME" 2>/dev/null || echo "?")
echo
if [[ "$CODE" == "0" ]]; then
  echo "==> Training finished. Client $CLIENT_ID has stopped."
else
  echo "==> The client stopped with an error (exit code $CODE). Send the log above to the server owner."
fi
$D rm -f "$NAME" >/dev/null 2>&1 || true
