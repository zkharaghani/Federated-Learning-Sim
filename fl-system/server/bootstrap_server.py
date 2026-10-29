#!/usr/bin/env python3
"""Provisioning (bootstrap) server — Python standard library only.

Endpoints (HTTPS, served with the same server certificate as the SuperLink):
  GET  /ca.crt                      public CA cert (clients pin its SHA-256)
  GET  /bundle/<client_id>          per-client tar.gz: Dockerfile, compose file,
                                    install_docker.sh, certs/ca.crt, client.env
                                    (requires  Authorization: Bearer <token>)
  POST /ready                       client reports it is ready
                                    JSON {client_id, docker_version, container}
                                    (requires  Authorization: Bearer <token>)
  GET  /status                      which clients downloaded / are ready (localhost only)

When every client in CLIENTS has reported ready, the file state/ALL_READY is
written so `start_server.sh` can launch the training run.
"""

from __future__ import annotations

import hmac
import io
import json
import os
import ssl
import tarfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_env(path: Path) -> dict[str, str]:
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"')
    return env


CFG = load_env(HERE / "config.env")
CLIENTS = CFG["CLIENTS"].split()
CERTS = HERE / "certs"
BUNDLE_DIR = HERE / "client_bundle"
STATE = HERE / "state"
STATE.mkdir(exist_ok=True)
TOKENS = {c: (HERE / "tokens" / c).read_text().strip() for c in CLIENTS}
LOCK = threading.Lock()
STATUS: dict[str, dict] = {c: {"bundle": False, "ready": False} for c in CLIENTS}


def build_bundle(client_id: str) -> bytes:
    """Tar.gz with the docker files + CA cert + this client's settings."""
    env = (
        f"CLIENT_ID={client_id}\n"
        f"SUPERLINK_ADDRESS={CFG['SERVER_IP']}:{CFG['SUPERLINK_PORT']}\n"
        f"PARTITION_ID={CLIENTS.index(client_id)}\n"
        f"NUM_PARTITIONS={len(CLIENTS)}\n"
        f"FLWR_VERSION={CFG['FLWR_VERSION']}\n"
    ).encode()
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for f in sorted(BUNDLE_DIR.iterdir()):
            tar.add(f, arcname=f"fl-client/{f.name}")
        tar.add(CERTS / "ca.crt", arcname="fl-client/certs/ca.crt")
        info = tarfile.TarInfo("fl-client/client.env")
        info.size, info.mtime = len(env), int(time.time())
        tar.addfile(info, io.BytesIO(env))
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    server_version = "FLBootstrap/1.0"

    def log_message(self, fmt, *args):
        print(f"[bootstrap] {self.client_address[0]} " + fmt % args, flush=True)

    def _send(self, code: int, body: bytes, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj):
        self._send(code, json.dumps(obj).encode())

    def _auth(self, client_id: str) -> bool:
        token = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        expected = TOKENS.get(client_id)
        return bool(expected) and hmac.compare_digest(token, expected)

    def do_GET(self):
        if self.path == "/ca.crt":
            return self._send(200, (CERTS / "ca.crt").read_bytes(), "application/x-pem-file")
        if self.path.startswith("/bundle/"):
            cid = self.path.split("/", 2)[2]
            if not self._auth(cid):
                return self._json(401, {"error": "bad client id or token"})
            with LOCK:
                STATUS[cid]["bundle"] = True
            print(f"[bootstrap] sending docker bundle + certificates to {cid}", flush=True)
            return self._send(200, build_bundle(cid), "application/gzip")
        if self.path == "/status" and self.client_address[0] in ("127.0.0.1", "::1"):
            with LOCK:
                return self._json(200, STATUS)
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/ready":
            return self._json(404, {"error": "not found"})
        try:
            data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except Exception:
            return self._json(400, {"error": "invalid json"})
        cid = data.get("client_id", "")
        if not self._auth(cid):
            return self._json(401, {"error": "bad client id or token"})
        with LOCK:
            STATUS[cid].update(ready=True, ip=self.client_address[0], **{
                k: str(data.get(k, "")) for k in ("docker_version", "container", "hostname")
            })
            n_ready = sum(s["ready"] for s in STATUS.values())
            print(f"[bootstrap] {cid} is READY ({n_ready}/{len(CLIENTS)}) {data}", flush=True)
            if n_ready == len(CLIENTS):
                (STATE / "ALL_READY").write_text(json.dumps(STATUS, indent=2))
                print("[bootstrap] ALL CLIENTS READY -> training can start", flush=True)
        self._json(200, {"ok": True, "ready": n_ready, "expected": len(CLIENTS)})


def main():
    (STATE / "ALL_READY").unlink(missing_ok=True)
    port = int(CFG["BOOTSTRAP_PORT"])
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(CERTS / "server.pem", CERTS / "server.key")
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"[bootstrap] listening on https://0.0.0.0:{port}  clients={CLIENTS}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
