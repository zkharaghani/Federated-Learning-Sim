#!/usr/bin/env bash
if docker info >/dev/null 2>&1; then D="docker"; else D="sudo docker"; fi
$D rm -f fl-server fl-client1 >/dev/null 2>&1; echo "Server and client 1 stopped."
