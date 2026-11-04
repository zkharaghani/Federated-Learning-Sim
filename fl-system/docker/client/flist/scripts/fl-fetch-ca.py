#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import hmac
import os
import ssl
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path


def bootstrap_url() -> str:
    configured = os.environ.get("CA_CERT_URL", "").strip()
    if configured:
        if not configured.startswith("http://"):
            raise ValueError("CA_CERT_URL must use http://; authenticity is provided by HMAC")
        return configured

    address = os.environ.get("SUPERLINK_ADDRESS", "").strip()
    if not address:
        raise ValueError("SUPERLINK_ADDRESS is required")
    if address.startswith("["):
        closing = address.find("]")
        if closing < 0:
            raise ValueError("invalid bracketed IPv6 SUPERLINK_ADDRESS")
        host = address[: closing + 1]
    else:
        host, separator, _ = address.rpartition(":")
        if not separator or not host:
            raise ValueError("SUPERLINK_ADDRESS must use host:port")
    port = os.environ.get("CA_BOOTSTRAP_PORT", "8443")
    if not port.isdigit() or not (1 <= int(port) <= 65535):
        raise ValueError("CA_BOOTSTRAP_PORT must be between 1 and 65535")
    return f"http://{host}:{port}/ca.crt"


def main() -> None:
    token = os.environ.get("CA_BOOTSTRAP_TOKEN", "")
    if len(token) < 32:
        raise ValueError("CA_BOOTSTRAP_TOKEN must contain at least 32 characters")

    url = bootstrap_url()
    print(f"[client] downloading the public CA from {url}", flush=True)
    request = urllib.request.Request(url, headers={"Accept": "application/x-pem-file"})
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status != 200:
            raise RuntimeError(f"CA bootstrap returned HTTP {response.status}")
        pem = response.read(1024 * 1024 + 1)
        signature = response.headers.get("X-CA-HMAC-SHA256", "")

    if len(pem) > 1024 * 1024:
        raise ValueError("downloaded CA exceeds 1 MiB")
    expected = hmac.new(token.encode(), pem, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        raise ValueError("CA bootstrap HMAC verification failed")
    ssl.PEM_cert_to_DER_cert(pem.decode("ascii"))

    cert_dir = Path(os.environ.get("CERTS_DIR", "/disk1/certs"))
    cert_dir.mkdir(parents=True, exist_ok=True)
    destination = cert_dir / "ca.crt"
    with tempfile.NamedTemporaryFile(dir=cert_dir, delete=False) as temporary:
        temporary.write(pem)
        temporary_path = Path(temporary.name)
    temporary_path.chmod(0o644)
    temporary_path.replace(destination)
    fingerprint = hashlib.sha256(pem).hexdigest()
    print(f"[client] CA verified and saved (SHA-256 {fingerprint})", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError, RuntimeError, urllib.error.URLError) as error:
        print(f"[client] failed to bootstrap CA: {error}", file=sys.stderr)
        raise SystemExit(1)
