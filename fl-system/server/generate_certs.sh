#!/usr/bin/env bash
# Creates a private CA and a server certificate for SERVER_IP, plus one
# random enrollment token per client.  Run once on the server.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env

CERT_DIR=certs
mkdir -p "$CERT_DIR" tokens
chmod 700 "$CERT_DIR" tokens

if [[ -f "$CERT_DIR/ca.crt" && "${1:-}" != "--force" ]]; then
  echo "Certificates already exist in $CERT_DIR (use --force to regenerate)."
else
  echo "==> Creating CA"
  openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "$CERT_DIR/ca.key" -sha256 -days 365 \
    -subj "/O=FL-Lab/CN=FL-Lab Root CA" -out "$CERT_DIR/ca.crt" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"

  echo "==> Creating server certificate for IP $SERVER_IP"
  cat > "$CERT_DIR/server.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
O  = FL-Lab
CN = $SERVER_IP
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
[v3_sign]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
[alt]
IP.1  = $SERVER_IP
IP.2  = 127.0.0.1
DNS.1 = localhost
DNS.2 = superlink
EOF
  openssl genrsa -out "$CERT_DIR/server.key" 4096 2>/dev/null
  openssl req -new -key "$CERT_DIR/server.key" -out "$CERT_DIR/server.csr" -config "$CERT_DIR/server.cnf"
  openssl x509 -req -in "$CERT_DIR/server.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
    -CAcreateserial -out "$CERT_DIR/server.pem" -days 365 -sha256 \
    -extensions v3_sign -extfile "$CERT_DIR/server.cnf" 2>/dev/null
  rm -f "$CERT_DIR/server.csr"
  chmod 600 "$CERT_DIR"/*.key
  # Flower containers run as non-root: key must be readable by the container user
  chmod 644 "$CERT_DIR/server.key"
fi

echo "==> Enrollment tokens"
for c in $CLIENTS; do
  [[ -f "tokens/$c" ]] || openssl rand -hex 24 > "tokens/$c"
done

FP=$(openssl x509 -in "$CERT_DIR/ca.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
echo "$FP" > "$CERT_DIR/ca.sha256"

echo
echo "================  give each client these 4 values  ================"
echo "SERVER     = $SERVER_IP:$BOOTSTRAP_PORT"
echo "CA_SHA256  = $FP"
for c in $CLIENTS; do
  echo "$c  TOKEN = $(cat tokens/$c)"
done
echo "===================================================================="
