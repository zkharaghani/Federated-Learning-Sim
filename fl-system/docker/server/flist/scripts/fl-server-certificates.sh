#!/bin/sh
set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CERTS_DIR="${CERTS_DIR:-/disk1/certs}"
SERVER_ADDRESS="${SERVER_ADDRESS:-}"

detect_address() {
    ip -4 -o addr show scope global \
        | awk '{ sub(/\/.*/, "", $4); print $4 }' \
        | python3 -c '
import ipaddress
import sys

addresses = [line.strip() for line in sys.stdin if line.strip()]
public = [address for address in addresses if ipaddress.ip_address(address).is_global]
selected = (public or addresses)
if selected:
    print(selected[0])
'
}

validate_address() {
    python3 - "$1" <<'PY'
import ipaddress
import re
import sys

value = sys.argv[1].strip()
if not value or "\n" in value or "\r" in value:
    raise SystemExit("SERVER_ADDRESS is empty or contains a line break")

try:
    normalized = str(ipaddress.ip_address(value))
except ValueError:
    if len(value) > 253 or not re.fullmatch(
        r"(?=.{1,253}\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*"
        r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?",
        value,
    ):
        raise SystemExit("SERVER_ADDRESS must be an IPv4, IPv6, or DNS name without a port")
    normalized = value.lower()

print(normalized)
PY
}

if [ -z "$SERVER_ADDRESS" ]; then
    SERVER_ADDRESS="$(detect_address)"
fi
[ -n "$SERVER_ADDRESS" ] || {
    echo "[server] cannot detect a global IP; set SERVER_ADDRESS to the public IP or DNS name" >&2
    exit 1
}
SERVER_ADDRESS="$(validate_address "$SERVER_ADDRESS")"

mkdir -p "$CERTS_DIR"
if [ -s "$CERTS_DIR/ca.crt" ] \
   && [ -s "$CERTS_DIR/server.pem" ] \
   && [ -s "$CERTS_DIR/server.key" ]; then
    if openssl x509 -in "$CERTS_DIR/server.pem" -noout -checkip "$SERVER_ADDRESS" >/dev/null 2>&1 \
       || openssl x509 -in "$CERTS_DIR/server.pem" -noout -checkhost "$SERVER_ADDRESS" >/dev/null 2>&1; then
        echo "[server] reusing TLS certificate for $SERVER_ADDRESS"
        exit 0
    fi
    echo "[server] persisted certificate does not match $SERVER_ADDRESS; regenerating it"
fi

tmp_dir="$(mktemp -d "$CERTS_DIR/.generate.XXXXXX")"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

case "$SERVER_ADDRESS" in
    *:*) subject_alt_name="IP.1 = $SERVER_ADDRESS" ;;
    *[!0-9.]*)
        subject_alt_name="DNS.1 = $SERVER_ADDRESS"
        ;;
    *) subject_alt_name="IP.1 = $SERVER_ADDRESS" ;;
esac

cat > "$tmp_dir/server.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
O = FL-Lab
CN = $SERVER_ADDRESS
[v3_sign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
[alt]
$subject_alt_name
IP.2 = 127.0.0.1
DNS.2 = localhost
DNS.3 = superlink
EOF

echo "[server] generating TLS certificate for $SERVER_ADDRESS"
openssl genrsa -out "$tmp_dir/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$tmp_dir/ca.key" -sha256 -days 365 \
    -subj "/O=FL-Lab/CN=FL-Lab Root CA" -out "$tmp_dir/ca.crt" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
openssl genrsa -out "$tmp_dir/server.key" 4096 2>/dev/null
openssl req -new -key "$tmp_dir/server.key" -out "$tmp_dir/server.csr" \
    -config "$tmp_dir/server.cnf"
openssl x509 -req -in "$tmp_dir/server.csr" \
    -CA "$tmp_dir/ca.crt" -CAkey "$tmp_dir/ca.key" -CAcreateserial \
    -out "$tmp_dir/server.pem" -days 365 -sha256 \
    -extensions v3_sign -extfile "$tmp_dir/server.cnf" 2>/dev/null
openssl verify -CAfile "$tmp_dir/ca.crt" "$tmp_dir/server.pem"

install -m 0644 "$tmp_dir/ca.crt" "$CERTS_DIR/ca.crt"
install -m 0644 "$tmp_dir/server.pem" "$CERTS_DIR/server.pem"
install -m 0600 "$tmp_dir/server.key" "$CERTS_DIR/server.key"
printf '%s\n' "$SERVER_ADDRESS" > "$CERTS_DIR/server-address"

echo "[server] TLS certificate ready; the CA private key was not persisted"
