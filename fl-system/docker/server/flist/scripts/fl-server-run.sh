#!/bin/sh
set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SUPERLINK_PORT="${SUPERLINK_PORT:-9092}"
NUM_CLIENTS="${NUM_CLIENTS:-2}"
NUM_ROUNDS="${NUM_ROUNDS:-30}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-3600}"
RUN_CONFIG="${RUN_CONFIG:-}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
CERTS_DIR="${CERTS_DIR:-/disk1/certs}"
RESULTS_DIR="${RESULTS_DIR:-/disk1/results}"
CA_BOOTSTRAP_PORT="${CA_BOOTSTRAP_PORT:-8443}"
export SUPERLINK_PORT NUM_CLIENTS NUM_ROUNDS WAIT_TIMEOUT RUN_CONFIG KEEP_RUNNING
export CERTS_DIR CA_BOOTSTRAP_PORT

case "$NUM_CLIENTS" in
    ''|*[!0-9]*|0)
        echo "[server] NUM_CLIENTS must be a positive integer" >&2
        exit 1
        ;;
esac

if [ "$(id -u)" = "0" ]; then
    mkdir -p "$CERTS_DIR" "$RESULTS_DIR"
    /usr/local/bin/fl-server-certificates.sh

    chown -R app:app "$RESULTS_DIR"
    chown app:app "$CERTS_DIR/ca.crt" "$CERTS_DIR/server.pem" "$CERTS_DIR/server.key"
    chmod 644 "$CERTS_DIR/ca.crt" "$CERTS_DIR/server.pem"
    chmod 600 "$CERTS_DIR/server.key"
    exec setpriv --reuid=1000 --regid=1000 --init-groups \
        env HOME=/home/app CERTS_DIR="$CERTS_DIR" RESULTS_DIR="$RESULTS_DIR" "$0" "$@"
fi

for file in ca.crt server.pem server.key; do
    [ -r "$CERTS_DIR/$file" ] || {
        echo "[server] cannot read $CERTS_DIR/$file" >&2
        exit 1
    }
done

mkdir -p "$HOME/.flwr" "$RESULTS_DIR"
cat > "$HOME/.flwr/config.toml" <<EOF
[superlink]
default = "fl-server"

[superlink.fl-server]
address = "127.0.0.1:${SUPERLINK_PORT}"
root-certificates = "${CERTS_DIR}/ca.crt"
EOF

python3 /usr/local/bin/fl-ca-bootstrap.py &
bootstrap_pid=$!
superlink_pid=
cleanup() {
    [ -z "$superlink_pid" ] || kill "$superlink_pid" 2>/dev/null || true
    kill "$bootstrap_pid" 2>/dev/null || true
    [ -z "$superlink_pid" ] || wait "$superlink_pid" 2>/dev/null || true
    wait "$bootstrap_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

echo "[server] starting SuperLink on 0.0.0.0:${SUPERLINK_PORT} (TLS)"
flower-superlink \
    --host 0.0.0.0 \
    --port "$SUPERLINK_PORT" \
    --ssl-ca-certfile "$CERTS_DIR/ca.crt" \
    --ssl-certfile "$CERTS_DIR/server.pem" \
    --ssl-keyfile "$CERTS_DIR/server.key" \
    --disable-runtime-dependency-installation &
superlink_pid=$!

attempt=0
until flwr ls fl-server >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 60 ]; then
        echo "[server] SuperLink did not become ready" >&2
        exit 1
    fi
    kill -0 "$superlink_pid" 2>/dev/null || {
        echo "[server] SuperLink exited before becoming ready" >&2
        exit 1
    }
    sleep 1
done

kill -0 "$bootstrap_pid" 2>/dev/null || {
    echo "[server] CA bootstrap service exited before becoming ready" >&2
    exit 1
}

echo "[server] SuperLink is ready; waiting for ${NUM_CLIENTS} clients"
log_file="$RESULTS_DIR/run-$(date +%Y%m%d-%H%M%S).log"
status_file="/tmp/flwr-run-status"
rm -f "$status_file"
set +e
{
    flwr run /app fl-server --stream \
        --run-config "num-rounds=${NUM_ROUNDS} num-clients=${NUM_CLIENTS} wait-timeout=${WAIT_TIMEOUT} ${RUN_CONFIG}" \
        2>&1
    printf '%s\n' "$?" > "$status_file"
} | tee "$log_file"
set -e

run_status="$(cat "$status_file" 2>/dev/null || printf '1')"

grep -o 'HISTORY_JSON .*' "$log_file" \
    | sed 's/^HISTORY_JSON //' > "$RESULTS_DIR/history.json" || true

if [ "$run_status" -ne 0 ] || ! grep -q "training finished" "$log_file"; then
    echo "[server] run failed; see $log_file" >&2
    exit 1
fi

echo "[server] run finished; results: $RESULTS_DIR/history.json"
if [ "$KEEP_RUNNING" = "true" ]; then
    echo "[server] KEEP_RUNNING=true; SuperLink remains available"
    wait "$superlink_pid"
fi
