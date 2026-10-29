# 2-client Federated Learning with Flower (TLS + Docker, synthetic or stored data)

Model: linear regression `y = Xw + b` (NumPy). Every round each client does
**exactly one SGD step** and returns updated params + loss; the server takes the
weighted average (FedAvg) and sends it back. Every 5 rounds the global model is
scored on each client's local test split (RMSE, R²).

**Data per client:** by default each client generates its own synthetic dataset.
With `--data-path` a client trains on its own stored `.npz` (`X_train`, `y_train`
[, `X_test`, `y_test`]) or `.csv` (last column = target) file instead. The file is
mounted read-only into the container and never leaves that machine. Features are
normalised with a global mean/std the server builds from per-client sums (no raw rows
are shared), and the learning rate is scaled automatically to the number of features.


## Layout
```
server/   config.env, generate_certs.sh, bootstrap_server.py, start_server.sh,
          run_training.sh, stop_server.sh, docker-compose.yml, Dockerfile.superlink
server/client_bundle/   what gets shipped to clients: Dockerfile, docker-compose.yml, install_docker.sh
client/   join_federation.py  (the only file a client needs; Python stdlib only)
fl-app/   the Flower App (ServerApp + ClientApp + data loading/model)
docker/   self-contained server and client images for a dataspace (see docker/README.md)
```

## Run it

**Server** (Linux with Docker; also `pip install flwr==1.40.0` on the host for the `flwr` CLI)
1. Edit `server/config.env` → set `SERVER_IP` to the address clients can reach.
2. Open TCP ports **9092** and **8443** in the firewall.
3. `cd server && ./start_server.sh`
   - creates CA + server cert (SAN = SERVER_IP) and one token per client
   - starts SuperLink (TLS) and the bootstrap service
   - prints `CA_SHA256` and the tokens, then waits for both clients to be READY
   - then automatically runs the training and streams logs

**Each client** (copy `client/join_federation.py` there; needs Python 3.9+ and sudo for Docker install)
```bash
python3 join_federation.py --server <SERVER_IP>:8443 --client-id client1 \
    --token <TOKEN_FOR_CLIENT1> --ca-sha256 <CA_SHA256>
```
(use `client2` + its token on the second machine). Add `--data-path /path/to/data.npz`
to train on a stored dataset instead of synthetic data; both clients' files must have
the same number of features. The script verifies the CA,
downloads the bundle, installs Docker if missing, builds/starts the SuperNode
container and reports READY. As soon as both are ready the server starts training.

Re-run training later: `cd server && ./run_training.sh` (override e.g. `-c "num-rounds=50 lr=0.02"`).
Stop: `./stop_server.sh` on the server, `docker compose down` in `fl-client-home/fl-client` on clients.

**Testing on one machine without Docker:** set `SERVER_IP=127.0.0.1`, run
`./start_server.sh --native`, and run the join command twice with `--native`.

## Hyper-parameters (`fl-app/pyproject.toml`)
`num-rounds=30, lr=0.5, lr-auto=true, batch-size=32, samples-per-client=500 (synthetic only), num-clients=2, eval-every=5`

## Example output (tested)
Synthetic data:
```
[server] round  10: client losses={'client1': 0.0004, 'client2': 0.0004}  averaged loss=0.0004  | test RMSE=0.1046 R²=0.999
[server] final w = [2.004, -2.989, 0.49, 1.496, -0.999]  (synthetic truth [2.0, -3.0, 0.5, 1.5, -1.0])
```
Stored `.npz` files shaped like the MoniFun forest data (X = 1309×1×19×40, flattened to 760 features; generated test files, not the real Zenodo data):
```
[server] features=760  learning rate used=0.01449
[server] round  30: client losses={'client1': 0.3242, 'client2': 0.3961}  averaged loss=0.3602  | test RMSE=64.6068 R²=0.559
```

## Security notes
- All traffic is TLS (private CA). Clients pin the CA by SHA-256, so the first download can't be spoofed.
- Bundles and READY require a per-client token (`server/tokens/`). Keep `server/certs/ca.key` secret.
- For production also enable Flower SuperNode authentication (`--enable-supernode-auth`) and rotate tokens.
