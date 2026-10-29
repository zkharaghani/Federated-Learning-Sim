#!/usr/bin/env bash
# One command on the server:  ./start_server.sh            (Docker)
#                              ./start_server.sh --native   (no Docker, for testing)
# 1) certificates + tokens  2) SuperLink (TLS) + bootstrap service
# 3) wait until both clients report READY  4) launch the FL training run
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env
MODE="${1:-docker}"

./generate_certs.sh
rm -f state/ALL_READY

if [[ "$MODE" == "--native" ]]; then
  mkdir -p logs
  echo "==> Starting SuperLink natively on 0.0.0.0:$SUPERLINK_PORT (TLS)"
  nohup flower-superlink --host 0.0.0.0 --port "$SUPERLINK_PORT" \
    --ssl-ca-certfile certs/ca.crt --ssl-certfile certs/server.pem --ssl-keyfile certs/server.key \
    > logs/superlink.log 2>&1 & echo $! > logs/superlink.pid
  echo "==> Starting bootstrap service on 0.0.0.0:$BOOTSTRAP_PORT"
  nohup python3 -u bootstrap_server.py > logs/bootstrap.log 2>&1 & echo $! > logs/bootstrap.pid
else
  echo "==> Starting SuperLink + bootstrap containers"
  docker compose --env-file config.env up -d --build
fi

echo
echo "On each client machine run (values printed above):"
echo "  python3 join_federation.py --server $SERVER_IP:$BOOTSTRAP_PORT \\"
echo "     --client-id <client1|client2> --token <TOKEN> --ca-sha256 $(cat certs/ca.sha256)"
echo
echo "==> Waiting for all clients to report READY ..."
until [[ -f state/ALL_READY ]]; do sleep 3; done
echo "==> All clients ready:"; cat state/ALL_READY

./run_training.sh
