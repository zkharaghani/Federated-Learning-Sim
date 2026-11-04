#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: $0 <version>" >&2
    exit 2
fi

docker_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$docker_dir/.." && pwd)"
version="$1"
archive="$docker_dir/dist/fl-client-threefold-${version}.tar.gz"
partial="${archive}.partial"
listing="${archive}.listing"

mkdir -p "$docker_dir/dist"
cleanup() {
    rm -f -- "$partial" "$listing"
}
trap cleanup EXIT

docker buildx build \
    --progress plain \
    --platform linux/amd64 \
    -f "$docker_dir/client/Dockerfile.threefold" \
    --output type=tar,dest=- \
    "$project_dir" | gzip -1 > "$partial"

gzip -t "$partial"
tar -tzf "$partial" > "$listing"
grep -Eq '^(\./)?(usr/)?sbin/zinit$' "$listing"
grep -Eq '^(\./)?etc/zinit/client\.yaml$' "$listing"
grep -Eq '^(\./)?etc/zinit/sshd\.yaml$' "$listing"
grep -Eq '^(\./)?usr/local/bin/fl-client-run\.sh$' "$listing"
grep -Eq '^(\./)?usr/local/bin/fl-fetch-ca\.py$' "$listing"
grep -Eq '^(\./)?usr/local/bin/fl-sshd-run\.sh$' "$listing"
grep -Eq '^(\./)?app/synthfl/client_app\.py$' "$listing"
grep -Eq '^(\./)?usr/local/bin/flower-supernode$' "$listing"

mv -- "$partial" "$archive"
rm -f -- "$listing"
trap - EXIT

sha256sum "$archive"
ls -lh "$archive"
printf 'Created the TFGrid client rootfs at %s\n' "$archive"
