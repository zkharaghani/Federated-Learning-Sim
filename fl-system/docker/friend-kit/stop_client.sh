#!/usr/bin/env bash
cd "$(dirname "$0")"; source ./client.env
if docker info >/dev/null 2>&1; then D="docker"; else D="sudo docker"; fi
$D rm -f "fl-${CLIENT_ID}" && echo "Client ${CLIENT_ID} stopped."
