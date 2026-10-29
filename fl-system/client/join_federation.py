#!/usr/bin/env python3
"""Run this on each client machine (needs only Python 3.9+ and internet access).

  python3 join_federation.py --server 192.168.1.10:8443 --client-id client1 \
        --token <TOKEN> --ca-sha256 <FINGERPRINT> [--data-path /path/to/data.npz]

Steps:
  1. download the server CA certificate and verify its SHA-256 fingerprint (pinning)
  2. download this client's bundle (Docker files + certificates + settings) over
     verified TLS, authenticated with the enrollment token
  3. install Docker if missing (install_docker.sh)
  4. build + start the Flower SuperNode container (docker compose up -d --build)
  5. check the container is running, then POST /ready to the server

--data-path  local .npz/.csv file to train on (omit -> synthetic data).
             It is mounted read-only into the container; it never leaves this machine.
--native  skips Docker and runs `flower-supernode` directly (for testing on one box).
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tarfile
import time
import urllib.request
from pathlib import Path


def log(msg: str) -> None:
    print(f"[join] {msg}", flush=True)


def fetch_ca(server: str, expected_sha256: str) -> bytes:
    host, port = server.rsplit(":", 1)
    # The CA is not trusted yet, so fetch it without verification and pin it.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(f"https://{server}/ca.crt", context=ctx, timeout=20) as r:
        pem = r.read()
    der = ssl.PEM_cert_to_DER_cert(pem.decode())
    got = hashlib.sha256(der).hexdigest()
    if got != expected_sha256.lower().replace(":", ""):
        sys.exit(f"[join] CA fingerprint MISMATCH (got {got}). Aborting - possible MITM.")
    log("CA certificate fingerprint verified")
    return pem


def verified_ctx(ca_pem: bytes) -> ssl.SSLContext:
    ctx = ssl.create_default_context(cadata=ca_pem.decode())
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx


def request(url, ctx, token, data=None):
    req = urllib.request.Request(url, data=data, headers={"Authorization": f"Bearer {token}"})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
        return r.read()


def read_env(path: Path) -> dict[str, str]:
    return dict(
        l.split("=", 1) for l in path.read_text().splitlines() if "=" in l and not l.startswith("#")
    )


def docker_cmd() -> list[str]:
    """`docker` or `sudo docker` (right after install the user isn't in the group yet)."""
    if subprocess.run(["docker", "info"], capture_output=True).returncode == 0:
        return ["docker"]
    return ["sudo", "docker"]


def start_docker(workdir: Path, env: dict[str, str]) -> tuple[str, str]:
    log("installing Docker if needed ...")
    subprocess.run(["bash", str(workdir / "install_docker.sh")], check=True)
    d = docker_cmd()
    log("building and starting the SuperNode container ...")
    subprocess.run(d + ["compose", "--env-file", "client.env", "up", "-d", "--build"],
                   cwd=workdir, check=True)
    name = f"fl-supernode-{env['CLIENT_ID']}"
    for _ in range(30):
        out = subprocess.run(d + ["inspect", "-f", "{{.State.Running}}", name],
                             capture_output=True, text=True).stdout.strip()
        if out == "true":
            time.sleep(5)  # give it time to connect; crash -> restart loop shows here
            again = subprocess.run(d + ["inspect", "-f", "{{.State.Running}} {{.RestartCount}}", name],
                                   capture_output=True, text=True).stdout.split()
            if again and again[0] == "true" and again[1] == "0":
                version = subprocess.run(d + ["--version"], capture_output=True, text=True).stdout.strip()
                return version, name
        time.sleep(2)
    subprocess.run(d + ["logs", "--tail", "50", name])
    sys.exit("[join] SuperNode container did not start correctly (logs above)")


def add_local_data(workdir: Path, env: dict[str, str], data_path: str | None) -> None:
    """Append local data settings to client.env (used by compose / native mode)."""
    lines = ["DATA_DIR=./data", "DATA_PATH_IN_CONTAINER=", "DATA_PATH_HOST="]
    (workdir / "data").mkdir(exist_ok=True)
    if data_path:
        p = Path(data_path).expanduser().resolve()
        if not p.is_file() or p.suffix not in (".npz", ".csv"):
            sys.exit(f"[join] --data-path must be an existing .npz or .csv file: {p}")
        lines = [f"DATA_DIR={p.parent}", f"DATA_PATH_IN_CONTAINER=/data/{p.name}", f"DATA_PATH_HOST={p}"]
        log(f"local dataset: {p} (mounted read-only, stays on this machine)")
    else:
        log("no --data-path given -> client will use synthetic data")
    with (workdir / "client.env").open("a") as f:
        f.write("\n".join(lines) + "\n")
    env.update(dict(l.split("=", 1) for l in lines))


def start_native(workdir: Path, env: dict[str, str]) -> tuple[str, str]:
    exe = shutil.which("flower-supernode") or sys.exit("flower-supernode not found (pip install flwr)")
    logf = open(workdir / "supernode.log", "w")
    p = subprocess.Popen(
        [exe, f"--superlink={env['SUPERLINK_ADDRESS']}",
         f"--root-certificates={workdir / 'certs' / 'ca.crt'}",
         f"--node-config=client-id=\"{env['CLIENT_ID']}\" partition-id={env['PARTITION_ID']} "
         f"num-partitions={env['NUM_PARTITIONS']} data-path=\"{env['DATA_PATH_HOST']}\"",
         f"--port={9094 + int(env['PARTITION_ID'])}"],
        stdout=logf, stderr=subprocess.STDOUT, start_new_session=True,
    )
    time.sleep(5)
    if p.poll() is not None:
        sys.exit(f"[join] supernode exited, see {workdir / 'supernode.log'}")
    (workdir / "supernode.pid").write_text(str(p.pid))
    return "native (no docker)", f"pid {p.pid}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True, help="SERVER_IP:BOOTSTRAP_PORT")
    ap.add_argument("--client-id", required=True)
    ap.add_argument("--token", required=True)
    ap.add_argument("--ca-sha256", required=True)
    ap.add_argument("--dir", default="fl-client-home", help="where to unpack the bundle")
    ap.add_argument("--data-path", help="local .npz/.csv dataset (default: synthetic)")
    ap.add_argument("--native", action="store_true", help="run without Docker (testing)")
    a = ap.parse_args()

    ca = fetch_ca(a.server, a.ca_sha256)
    ctx = verified_ctx(ca)

    log(f"downloading bundle for {a.client_id} ...")
    blob = request(f"https://{a.server}/bundle/{a.client_id}", ctx, a.token)
    base = Path(a.dir).resolve()
    base.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        tar.extractall(base, filter="data")
    workdir = base / "fl-client"
    env = read_env(workdir / "client.env")
    log(f"bundle unpacked to {workdir}  (SuperLink {env['SUPERLINK_ADDRESS']}, "
        f"partition {env['PARTITION_ID']})")

    add_local_data(workdir, env, a.data_path)
    version, container = (start_native if a.native else start_docker)(workdir, env)
    log(f"SuperNode running: {container}")

    payload = json.dumps({"client_id": a.client_id, "docker_version": version,
                          "container": container, "hostname": socket.gethostname()}).encode()
    resp = json.loads(request(f"https://{a.server}/ready", ctx, a.token, payload))
    log(f"server acknowledged READY: {resp}")


if __name__ == "__main__":
    main()
