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

# TFGrid / Phase4AI deployment

This deployment uses two separate FLists and offers:

| Package | Build script | Output |
|---|---|---|
| Server | `docker/build_server_flist.sh <version>` | `docker/dist/fl-server-threefold-<version>.tar.gz` |
| Client | `docker/build_client_flist.sh <version>` | `docker/dist/fl-client-threefold-<version>.tar.gz` |
| Both | `docker/build_threefold_flists.sh <version>` | Both archives above |

## Build prerequisites

- Docker with the Buildx plugin;
- internet access while building images;
- enough free disk space for two approximately 160 MB compressed archives;
- an `amd64`-capable builder (native or emulated by Buildx).

Run commands from the repository root:

```bash
docker buildx version
docker/build_threefold_flists.sh v1
```

The version is an archive label and may be changed, for example:

```bash
docker/build_threefold_flists.sh v2
```

Each build script:

1. builds a flat `linux/amd64` root filesystem;
2. compresses it as `tar.gz`;
3. validates the gzip archive;
4. verifies required runtime files inside the archive;
5. prints SHA-256, file size, and output path.

Upload the resulting archives from `docker/dist/` to the Phase4AI Software
Repository before creating the offers.

## End-to-end flow

```text
Build and upload server FList
  -> create and buy server offer
  -> deploy server pass
  -> copy server public IP and exposed CA_BOOTSTRAP_TOKEN
  -> build and upload client FList
  -> create and buy client offer
  -> deploy client pass twice with distinct IDs and partitions
  -> both clients download and verify ca.crt
  -> both clients connect to SuperLink
  -> training starts automatically
```

## Server FList and offer

The server and both clients can run as separate TFGrid workloads. The server
workload contains the SuperLink and ServerApp; client workloads connect to its
public IPv4 address over TLS on TCP 9092.

Build and verify the flat `linux/amd64` rootfs:

```bash
docker/build_server_flist.sh v1
```

The archive is written to `docker/dist/fl-server-threefold-v1.tar.gz`. Upload
that archive to the Phase4AI Software Repository and deploy the resulting FList
with:

```text
Entrypoint: /sbin/zinit init
Public IPv4: enabled
Environment:
  ENABLE_SSH=1
  SSH_PUBLIC_KEY=
Data disk: mounted by the portal at /disk1
```

The training variables are optional. If omitted, the runtime uses:

```text
SUPERLINK_PORT=9092
NUM_CLIENTS=2
NUM_ROUNDS=30
WAIT_TIMEOUT=3600
KEEP_RUNNING=false
RUN_CONFIG=
```

Values supplied by the Software Repository environment override these defaults.
The server automatically detects its public IPv4 address and generates the CA,
server certificate, and private server key on first boot. Set `SERVER_ADDRESS`
only when the address cannot be detected from a global network interface or a
DNS name should be used instead.

Configure the server offer workload with a generated bootstrap token:

```json
{
  "environment": {
    "ENABLE_SSH": "1"
  },
  "secrets": [
    {
      "name": "CA_BOOTSTRAP_TOKEN",
      "generator": "token",
      "length": 48,
      "exposeToUser": true
    }
  ],
  "network": {
    "publicIPv4": true
  }
}
```

Use `docker/offers/server-user-input.json` as the artifact's
`userInputDeclarations`. The server deployment form then contains one field:

```text
NUM_CLIENTS=2
```

It must be a positive integer. Training starts after that many distinct clients
connect.

The one-time exposed `CA_BOOTSTRAP_TOKEN` is shown in the deployed pass metadata.
It authenticates the public CA returned by the server bootstrap endpoint. The
token is never sent to that endpoint.

The generated server secret may be labelled `Certificate download token`.
Use the same label for the client user-input field. Both map to the environment
variable `CA_BOOTSTRAP_TOKEN`.

`ENABLE_SSH=1` enables key-only SSH. The portal normally injects the selected
public key as `SSH_KEY`; it is intentionally not part of the workload's user
input schema. A provider-level `SSH_PUBLIC_KEY` environment value is also
accepted when needed.

`EXPOSE 9092`, `EXPOSE 8443`, and `EXPOSE 22` in the Dockerfile are
documentation only. They do not create a
TFGrid firewall or port mapping. The portal must allocate a public IPv4 address,
and the SuperLink must listen on `0.0.0.0:9092`. The current portal deployment
model assigns the public IP directly to the VM and does not define per-port
forwarding rules. TCP 8443 serves only the public CA with an HMAC signature.
SSH listens on TCP 22 only when `ENABLE_SSH=1`.

Generated runtime certificates persist under `/disk1/certs`. The CA private key
is used only during generation and is not persisted. Results persist in
`/disk1/results`. The server service is a zinit oneshot, so it does not start a
second training run after completion.

## Client FList and offer

The client offer does not contain a particular server IP. Use
`docker/offers/client-user-input.json` as the artifact's
`userInputDeclarations`. The client deployment form then contains exactly two
fields:

```text
SERVER_ADDRESS=<server public IPv4 without a port>
CA_BOOTSTRAP_TOKEN=<one-time exposed value from the server pass>
```

The current portal does not resolve outputs across passes. Copy both values from
the deployed server pass into each client deployment form:

```text
SERVER_ADDRESS=185.69.167.173
CA_BOOTSTRAP_TOKEN=<one-time exposed value from the server pass>
```

The client derives `SUPERLINK_ADDRESS=185.69.167.173:9092` and
`http://185.69.167.173:8443/ca.crt`. It downloads the public CA and verifies its
HMAC with `CA_BOOTSTRAP_TOKEN` before saving it. Existing
`SUPERLINK_ADDRESS`, `CA_CERT_URL`, and `CA_CERT_B64` variables remain available
as advanced overrides but are not user inputs.

`CLIENT_ID` and `PARTITION_ID` are generated from the orchestrator-provided
`DEPLOYMENT_ID`. Separate client passes therefore receive distinct identities
without additional form fields. Never pass `ca.key`, `server.key`, or
`server.pem` to a client.

Build and verify the flat `linux/amd64` client rootfs:

```bash
docker/build_client_flist.sh v1
```

Upload `docker/dist/fl-client-threefold-v1.tar.gz` and configure:

```text
Entrypoint: /sbin/zinit init
Public IPv4: enabled
Environment:
  ENABLE_SSH=1
  EXIT_AFTER_RUN=true
```

Recommended per-pass form fields:

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `SERVER_ADDRESS` | yes | none | Server public IPv4 without a port |
| `CA_BOOTSTRAP_TOKEN` | yes | none | One-time exposed token from the server pass |

Deploy the same client pass as many times as requested through the server's
`NUM_CLIENTS`. A client needs no inbound port for Flower; public IPv4 is
requested only for SSH.

The server submits its run immediately and waits for the user-provided
`NUM_CLIENTS`. Training starts automatically after that many distinct
SuperNodes connect.

## Deployment procedure

### 1. Deploy the server pass

Deploy the server pass with public IPv4 enabled. Wait until the pass reports a
public IP. Record:

```text
SERVER_PUBLIC_IP=<public IP reported by the deployment>
CA_BOOTSTRAP_TOKEN=<one-time exposed secret from the server pass>
```

The server starts SuperLink immediately and waits for the configured number of
clients. No manual `make_certs.sh` or `scp` operation is required.

### 2. Deploy the first client

Enter:

```text
SERVER_ADDRESS=<SERVER_PUBLIC_IP>
CA_BOOTSTRAP_TOKEN=<token from the server pass>
```

### 3. Deploy the remaining clients

Repeat the client pass deployment until the number selected in `NUM_CLIENTS` is
reached. Use the same server address and bootstrap token each time. Every
deployment ID produces a different client identity automatically.

Both clients download the same public CA. The private server key and CA private
key are never transferred to either client.

### 4. Connect over SSH

After the portal reports each client's public IP, use the private key matching
the public key selected during deployment:

```bash
ssh -i "$HOME/.ssh/id_ed25519" "root@<CLIENT_PUBLIC_IP>"
```

SSH password authentication is disabled. The private key remains on the
operator's machine.

### 5. Verify training

The server run waits until two distinct SuperNodes are connected. After both
client passes start, training begins automatically. Server results are stored
under:

```text
/disk1/results/
```

Client datasets remain local to their respective VMs. Leave `DATA_PATH` empty
to use synthetic data.

## Troubleshooting

| Symptom | Check |
|---|---|
| Server exits before SuperLink starts | `CA_BOOTSTRAP_TOKEN` exists and has at least 32 characters |
| Certificate does not match server | Set `SERVER_ADDRESS` explicitly to the public IP or DNS name used by clients |
| Client reports HMAC verification failure | Both client passes use the exact exposed token from this server pass |
| Client cannot download CA | Server public IPv4 is reachable on TCP 8443 |
| Client cannot connect to Flower | Server public IPv4 is reachable on TCP 9092 and `SUPERLINK_ADDRESS` includes `:9092` |
| SSH connection fails | Client has public IPv4, `ENABLE_SSH=1`, and the portal injected `SSH_KEY` |
| Training never starts | The number of connected client passes matches `NUM_CLIENTS` |

## Security constraints

- Give clients only the public `ca.crt`.
- Never copy `server.key` or `ca.key` to a client.
- Do not place a private SSH key in an offer or pass.
- Treat `CA_BOOTSTRAP_TOKEN` as sensitive and rotate it by deploying a new
  server pass.
- The CA endpoint uses HTTP, but the downloaded bytes are authenticated with
  HMAC before the client accepts them.
- `CA_CERT_B64` remains available only as an offline fallback.
