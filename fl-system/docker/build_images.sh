#!/usr/bin/env bash
# Builds both images and (optionally) exports them as .tar files you can hand to
# the dataspace operators (they load them with: docker load -i fl-server-1.0.tar).
#   ./build_images.sh            build only
#   ./build_images.sh --save     build + save tars into ./dist
#   REGISTRY=registry.example.org/fl ./build_images.sh --push   build + push
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=${TAG:-1.0}
docker build -f docker/server/Dockerfile -t fl-server:$TAG .
docker build -f docker/client/Dockerfile -t fl-client:$TAG .
case "${1:-}" in
  --save) mkdir -p docker/dist
          docker save fl-server:$TAG -o docker/dist/fl-server-$TAG.tar
          docker save fl-client:$TAG -o docker/dist/fl-client-$TAG.tar
          ls -lh docker/dist ;;
  --push) : "${REGISTRY:?set REGISTRY}"
          for i in fl-server fl-client; do
            docker tag $i:$TAG "$REGISTRY/$i:$TAG"; docker push "$REGISTRY/$i:$TAG"; done ;;
esac
