# Docker images for running in a dataspace

## Quick start: two computers (you = server + client 1, a friend = client 2)
On **your** computer, in this `docker` folder:
```bash
hostname -I                                # your IP, e.g. 192.168.1.23
bash make_friend_kit.sh 192.168.1.23       # -> dist/client2-kit.zip  (send this to your friend)
sudo ufw allow 9092/tcp                    # if your firewall is active
bash start_my_side.sh 192.168.1.23 30      # server + client 1, 30 rounds; shows the server log
```
Your **friend** unzips the kit and runs `bash install_docker.sh` (once), then
`bash run_client.sh`. The kit's own README explains every step, including WSL.
After the last round the server tells both clients training is finished, and
everything stops by itself (server, client 1 and her client). Set
`EXIT_AFTER_RUN=false` on a client to keep it running for several runs.
If your IP changes, run `make_friend_kit.sh` again and send the new kit.

---

Two self-contained images. All code and dependencies are inside them, so nothing
is installed at run time and the containers do not need internet access.

| Image | Runs | Needs mounted | Opens |
|---|---|---|---|
| `fl-server:1.0` | Flower SuperLink + ServerApp. Waits for the clients, checks they are ready, runs the training rounds, saves results | `/certs` (ca.crt, server.pem, server.key), `/results` (writable) | TCP 9092 |
| `fl-client:1.0` | Flower SuperNode + ClientApp. Trains on the local dataset | `/certs/ca.crt`, `/data` (read-only, the dataset) | outbound to the server only |

Raw data never leaves a client container. Only model parameters, losses, metrics
and aggregate sums for normalisation go to the server.

## 1. Build (on any machine with Docker and internet)
```bash
docker/build_images.sh --save      # -> docker/dist/fl-server-1.0.tar, fl-client-1.0.tar
# or push to the dataspace registry:
REGISTRY=registry.example.org/fl docker/build_images.sh --push
```
Hand over the tars (`docker load -i ...`) or the registry names.

## 2. Certificates
If the dataspace provides its own CA and server certificate, use those: name them
`ca.crt`, `server.pem` and `server.key`. Otherwise create them with every address the
clients will use for the server:
```bash
docker/make_certs.sh 10.0.5.20 fl-server.dataspace.example
```
The server gets all three files. Clients get **only** `ca.crt`. `ca.key` stays offline.

## 3. Run the server
```bash
docker run -d --name fl-server -p 9092:9092 \
  -v /path/certs:/certs:ro -v /path/results:/results \
  -e NUM_ROUNDS=30 -e NUM_CLIENTS=2 \
  fl-server:1.0
docker logs -f fl-server
```
| Variable | Default | Meaning |
|---|---|---|
| `NUM_ROUNDS` | 30 | training rounds (one SGD step per client per round) |
| `NUM_CLIENTS` | 2 | clients to wait for |
| `RUN_CONFIG` | – | other settings, e.g. `"lr=0.3 batch-size=64 eval-every=5"` |
| `KEEP_RUNNING` | false | keep the SuperLink up after the run |
| `SUPERLINK_PORT` | 9092 | listening port |

Results land in `/results`: the full log `run-<time>.log` and `history.json`
(per-round losses, test RMSE, R²). The container stops when the run ends unless
`KEEP_RUNNING=true`, and exits with code 1 if the run failed. The container fixes
the ownership of `/results` itself. If it is started with `--user`, the folder must
already be writable by that user. If it isn't, results go to `/tmp/results` inside
the container and a warning is printed.

## 4. Run each client (on the node that holds the data)
```bash
docker run -d --name fl-client1 \
  -v /path/ca.crt:/certs/ca.crt:ro \
  -v /path/to/dataset-folder:/data:ro \
  -e SUPERLINK_ADDRESS=fl-server.dataspace.example:9092 \
  -e CLIENT_ID=client1 -e PARTITION_ID=0 \
  -e DATA_PATH=/data/client_1_data.npz \
  fl-client:1.0
```
Second client: `CLIENT_ID=client2 PARTITION_ID=1` and its own dataset.

| Variable | Meaning |
|---|---|
| `SUPERLINK_ADDRESS` | server host:port. The host must be in the server certificate |
| `CLIENT_ID` | name shown in the server logs |
| `PARTITION_ID` | 0, 1, … (seed for synthetic data) |
| `DATA_PATH` | dataset inside the container: `.npz` (`X_train`, `y_train` [, `X_test`, `y_test`]) or `.csv` (last column = target). Empty = synthetic data |

Both clients' datasets must have the same number of features. Multi-dimensional
`X` is flattened.

Start order doesn't matter: clients keep retrying until the server is up, and the
server waits for all clients. Clients also keep retrying after the server finishes,
so they're ready for the next run. Stop them with `docker rm -f fl-client1` when done.

## 5. Test everything on one machine
```bash
docker/make_certs.sh localhost
cd docker && docker compose -f docker-compose.test.yml up --build --abort-on-container-exit --exit-code-from superlink
# with files: put them in docker/data/client1 and docker/data/client2, then
CLIENT1_DATA=/data/a.npz CLIENT2_DATA=/data/b.npz docker compose -f docker-compose.test.yml up --abort-on-container-exit --exit-code-from superlink
```
`--abort-on-container-exit` stops the clients as soon as the server finishes.
Results are in `docker/results/`.

## What to give the dataspace operators
- the two images (tars or registry names)
- `ca.crt` for each client node, plus the server certificate files (or use theirs)
- the variables above: server address and port, client IDs, dataset paths
- the firewall rule: clients → server TCP 9092

`bootstrap_server.py` and `join_federation.py` in the main project are not needed
here. They are for when you set up the machines yourself. In a dataspace, the
operator deploys the containers and Flower's own readiness check replaces the
"ready" message.
