#!/usr/bin/env bash
cd "$(dirname "$0")"
for p in logs/*.pid; do [[ -f "$p" ]] && kill "$(cat "$p")" 2>/dev/null; rm -f "$p"; done
docker compose --env-file config.env down 2>/dev/null || true
echo stopped
