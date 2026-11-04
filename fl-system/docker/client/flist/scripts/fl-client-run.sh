#!/bin/sh
set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SERVER_ADDRESS="${SERVER_ADDRESS:-}"
SUPERLINK_ADDRESS="${SUPERLINK_ADDRESS:-}"
if [ -z "$SUPERLINK_ADDRESS" ] && [ -n "$SERVER_ADDRESS" ]; then
    SERVER_ADDRESS="$(python3 - "$SERVER_ADDRESS" <<'PY'
import ipaddress
import sys

address = ipaddress.IPv4Address(sys.argv[1].strip())
if not address.is_global:
    raise SystemExit("SERVER_ADDRESS must be a public IPv4 address")
print(address)
PY
    )"
    SUPERLINK_ADDRESS="${SERVER_ADDRESS}:9092"
fi
[ -n "$SUPERLINK_ADDRESS" ] || {
    echo "[client] SERVER_ADDRESS or SUPERLINK_ADDRESS is required" >&2
    exit 1
}
export SUPERLINK_ADDRESS

CLIENT_ID="${CLIENT_ID:-${DEPLOYMENT_ID:-}}"
[ -n "$CLIENT_ID" ] || {
    echo "[client] DEPLOYMENT_ID or CLIENT_ID is required" >&2
    exit 1
}
PARTITION_ID="${PARTITION_ID:-}"
if [ -z "$PARTITION_ID" ]; then
    PARTITION_ID="$(printf '%s' "$CLIENT_ID" | cksum | awk '{ print $1 }')"
fi
DATA_PATH="${DATA_PATH:-}"
EXIT_AFTER_RUN="${EXIT_AFTER_RUN:-true}"
CERTS_DIR="${CERTS_DIR:-/disk1/certs}"
CA_CERT_FILE="$CERTS_DIR/ca.crt"
DONE_FILE="/tmp/fl-done-${CLIENT_ID}"

mkdir -p "$CERTS_DIR"
if [ -n "${CA_CERT_B64:-}" ]; then
    printf '%s' "$CA_CERT_B64" | base64 -d > "$CA_CERT_FILE"
    chmod 644 "$CA_CERT_FILE"
elif [ -n "${CA_BOOTSTRAP_TOKEN:-}" ]; then
    python3 /usr/local/bin/fl-fetch-ca.py
fi
[ -s "$CA_CERT_FILE" ] || {
    echo "[client] provide CA_CERT_B64, CA_BOOTSTRAP_TOKEN, or place ca.crt in $CERTS_DIR" >&2
    exit 1
}

if [ -n "$DATA_PATH" ] && [ ! -r "$DATA_PATH" ]; then
    echo "[client] DATA_PATH=$DATA_PATH is not readable" >&2
    exit 1
fi

chown app:app "$CA_CERT_FILE"
rm -f "$DONE_FILE"
echo "[client] $CLIENT_ID -> $SUPERLINK_ADDRESS  data=${DATA_PATH:-synthetic}"

set -- flower-supernode \
    --superlink "$SUPERLINK_ADDRESS" \
    --root-certificates "$CA_CERT_FILE" \
    --port "${CLIENTAPPIO_PORT:-9094}" \
    --node-config "client-id=\"${CLIENT_ID}\" partition-id=${PARTITION_ID} data-path=\"${DATA_PATH}\""

if [ "$EXIT_AFTER_RUN" != "true" ]; then
    exec setpriv --reuid=1000 --regid=1000 --init-groups env HOME=/home/app "$@"
fi

setpriv --reuid=1000 --regid=1000 --init-groups env HOME=/home/app FL_DONE_FILE="$DONE_FILE" "$@" &
client_pid=$!
cleanup() {
    kill "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

while kill -0 "$client_pid" 2>/dev/null; do
    if [ -f "$DONE_FILE" ]; then
        sleep 5
        echo "[client] $CLIENT_ID: training finished"
        exit 0
    fi
    sleep 1
done

wait "$client_pid"
