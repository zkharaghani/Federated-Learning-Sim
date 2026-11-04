#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: $0 <version>" >&2
    exit 2
fi

docker_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
version="$1"

"$docker_dir/build_server_flist.sh" "$version"
"$docker_dir/build_client_flist.sh" "$version"

printf '\nCreated both TFGrid rootfs archives:\n'
printf '  %s\n' "$docker_dir/dist/fl-server-threefold-${version}.tar.gz"
printf '  %s\n' "$docker_dir/dist/fl-client-threefold-${version}.tar.gz"
