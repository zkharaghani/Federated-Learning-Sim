#!/bin/sh
# 1) start SuperLink with TLS  2) submit the FL run  3) save results
set -eu

# Started as root only to make the mounted /results folder writable,
# then the script re-runs itself as the unprivileged user "app" (uid 1000).
if [ "$(id -u)" = "0" ]; then
  mkdir -p /results && chown -R 1000:1000 /results 2>/dev/null || true
  exec setpriv --reuid=1000 --regid=1000 --init-groups env HOME=/home/app "$0" "$@"
fi

cd "$HOME"
RESULTS=/results
if ! touch "$RESULTS/.write-test" 2>/dev/null; then
  echo "[server] WARNING: /results is not writable by uid $(id -u); saving results inside the container at /tmp/results"
  echo "[server]          fix on the host: sudo chown -R 1000:1000 <results folder>"
  RESULTS=/tmp/results; mkdir -p "$RESULTS"
fi
rm -f "$RESULTS/.write-test"

for f in ca.crt server.pem server.key; do
  [ -r "/certs/$f" ] || { echo "[server] missing /certs/$f (mount the certificate folder)"; exit 1; }
done

echo "[server] starting SuperLink on 0.0.0.0:${SUPERLINK_PORT} (TLS)"
flower-superlink --host 0.0.0.0 --port "${SUPERLINK_PORT}" \
  --ssl-ca-certfile /certs/ca.crt --ssl-certfile /certs/server.pem --ssl-keyfile /certs/server.key \
  --disable-runtime-dependency-installation &
SL_PID=$!

# flwr CLI connection to the local SuperLink (the cert contains 127.0.0.1)
mkdir -p "$HOME/.flwr"
cat > "$HOME/.flwr/config.toml" <<TOML
[superlink]
default = "fl-server"

[superlink.fl-server]
address = "127.0.0.1:${SUPERLINK_PORT}"
root-certificates = "/certs/ca.crt"
TOML

i=0
until flwr ls fl-server >/dev/null 2>&1; do
  i=$((i+1)); [ $i -gt 60 ] && { echo "[server] SuperLink did not start"; exit 1; }
  kill -0 $SL_PID 2>/dev/null || { echo "[server] SuperLink exited"; exit 1; }
  sleep 1
done
echo "[server] SuperLink is up; submitting run (it waits for ${NUM_CLIENTS} clients)"

LOG="$RESULTS/run-$(date +%Y%m%d-%H%M%S).log"
set +e
{ flwr run /app fl-server --stream \
    --run-config "num-rounds=${NUM_ROUNDS} num-clients=${NUM_CLIENTS} ${RUN_CONFIG}" 2>&1
  echo $? > /tmp/flwr-rc; } | tee "$LOG"
set -e
grep -o 'HISTORY_JSON .*' "$LOG" | sed 's/^HISTORY_JSON //' > "$RESULTS/history.json" || true

STATUS=0
if [ "$(cat /tmp/flwr-rc)" != "0" ] || ! grep -q "training finished" "$LOG"; then
  echo "[server] RUN FAILED - see $LOG"; STATUS=1
else
  echo "[server] run finished OK; log: $LOG  history: $RESULTS/history.json"
fi

if [ "${KEEP_RUNNING}" = "true" ]; then
  echo "[server] KEEP_RUNNING=true -> SuperLink stays up for more runs"
  wait $SL_PID
else
  kill $SL_PID 2>/dev/null || true
fi
exit $STATUS
