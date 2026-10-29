#!/bin/sh
# Starts a Flower SuperNode that trains on the dataset at $DATA_PATH
# (a .npz/.csv inside the mounted /data folder). Empty DATA_PATH -> synthetic data.
set -eu
[ -n "${SUPERLINK_ADDRESS}" ] || { echo "[client] set SUPERLINK_ADDRESS=host:port"; exit 1; }
[ -r /certs/ca.crt ] || { echo "[client] missing /certs/ca.crt (mount the CA certificate)"; exit 1; }
if [ -n "${DATA_PATH}" ] && [ ! -r "${DATA_PATH}" ]; then
  echo "[client] DATA_PATH=${DATA_PATH} not found inside the container (mount it under /data)"; exit 1
fi
echo "[client] ${CLIENT_ID} -> ${SUPERLINK_ADDRESS}  data=${DATA_PATH:-synthetic}"
DONE_FILE="/tmp/fl-done-${CLIENT_ID}"
rm -f "$DONE_FILE"
set -- flower-supernode \
  --superlink "${SUPERLINK_ADDRESS}" \
  --root-certificates /certs/ca.crt \
  --port "${CLIENTAPPIO_PORT:-9094}" \
  --node-config "client-id=\"${CLIENT_ID}\" partition-id=${PARTITION_ID} num-partitions=${NUM_PARTITIONS} data-path=\"${DATA_PATH}\""

if [ "${EXIT_AFTER_RUN:-true}" != "true" ]; then
  # keep running and reconnecting (e.g. to take part in several runs)
  exec "$@"
fi

# EXIT_AFTER_RUN=true (default): stop when the server says training is finished
"$@" &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID || true; exit 0' TERM INT
while kill -0 "$PID" 2>/dev/null; do
  if [ -f "$DONE_FILE" ]; then
    sleep 5   # let the last reply reach the server
    echo "[client] ${CLIENT_ID}: training finished - stopping the client"
    kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true
    exit 0
  fi
  sleep 1
done
wait "$PID"
