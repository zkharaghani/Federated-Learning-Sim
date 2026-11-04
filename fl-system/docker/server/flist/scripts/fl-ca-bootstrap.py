#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import hmac
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CERTS_DIR = Path(os.environ.get("CERTS_DIR", "/disk1/certs"))
CA_FILE = CERTS_DIR / "ca.crt"
TOKEN = os.environ.get("CA_BOOTSTRAP_TOKEN", "")
PORT = int(os.environ.get("CA_BOOTSTRAP_PORT", "8443"))

if len(TOKEN) < 32:
    raise SystemExit("CA_BOOTSTRAP_TOKEN must contain at least 32 characters")


class Handler(BaseHTTPRequestHandler):
    server_version = "FL-CA-Bootstrap/1.0"

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"[ca-bootstrap] {self.client_address[0]} {fmt % args}", flush=True)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send(200, b"ok\n", "text/plain")
            return
        if self.path != "/ca.crt":
            self._send(404, b"not found\n", "text/plain")
            return

        pem = CA_FILE.read_bytes()
        signature = hmac.new(TOKEN.encode(), pem, hashlib.sha256).hexdigest()
        fingerprint = hashlib.sha256(pem).hexdigest()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-pem-file")
        self.send_header("Content-Length", str(len(pem)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-CA-HMAC-SHA256", signature)
        self.send_header("X-CA-SHA256", fingerprint)
        self.end_headers()
        self.wfile.write(pem)

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)


print(f"[ca-bootstrap] serving public CA on 0.0.0.0:{PORT}", flush=True)
ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
