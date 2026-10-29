#!/usr/bin/env bash
# Creates a private CA + server certificate.
#   ./make_certs.sh <server address> [more addresses...]
# Use every IP or DNS name the clients will use to reach the server, e.g.
#   ./make_certs.sh 10.0.5.20 fl-server.dataspace.example
# Skip this if the dataspace gives you its own CA + server certificate:
# just place them as certs/ca.crt, certs/server.pem, certs/server.key.
set -euo pipefail
cd "$(dirname "$0")"
[[ $# -ge 1 ]] || { echo "usage: $0 <server-ip-or-dns> [...]"; exit 1; }
mkdir -p certs
if [[ ! -w certs || -d certs/ca.crt ]]; then
  echo "The certs folder is owned by root (Docker created it during a run without certificates)."
  echo "Fix:  sudo rm -rf certs results   then run this script again."
  exit 1
fi
alt="IP.1 = 127.0.0.1"$'\n'"DNS.1 = localhost"$'\n'"DNS.2 = superlink"; i=2; d=3
for h in "$@"; do
  if [[ "$h" =~ ^[0-9.]+$ || "$h" == *:* ]]; then alt+=$'\n'"IP.$i = $h"; i=$((i+1))
  else alt+=$'\n'"DNS.$d = $h"; d=$((d+1)); fi
done
cat > certs/server.cnf <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
O  = FL-Lab
CN = $1
[v3_sign]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
[alt]
$alt
CNF
openssl genrsa -out certs/ca.key 4096 2>/dev/null
openssl req -x509 -new -nodes -key certs/ca.key -sha256 -days 365 \
  -subj "/O=FL-Lab/CN=FL-Lab Root CA" -out certs/ca.crt \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"
openssl genrsa -out certs/server.key 4096 2>/dev/null
openssl req -new -key certs/server.key -out certs/server.csr -config certs/server.cnf
openssl x509 -req -in certs/server.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
  -out certs/server.pem -days 365 -sha256 -extensions v3_sign -extfile certs/server.cnf 2>/dev/null
rm -f certs/server.csr
chmod 600 certs/ca.key; chmod 644 certs/server.key certs/ca.crt certs/server.pem  # containers run as uid 1000
openssl verify -CAfile certs/ca.crt certs/server.pem
echo "Give clients ONLY certs/ca.crt. Keep certs/ca.key private (not needed by any container)."
