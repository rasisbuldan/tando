#!/bin/bash
# Build tando-bench-base/-docker/-podman with a dedicated buildx builder (tando-bench-img), so its
# cache can be removed with the builder. A docker-container builder cannot use local images in
# FROM, so the three Dockerfiles are joined into one multi-stage file (targets base, docker, podman).
set -eu
cd "$(dirname "$0")"
docker buildx inspect tando-bench-img >/dev/null 2>&1 || docker buildx create --name tando-bench-img --driver docker-container >/dev/null
f=$(mktemp "${TMPDIR:-/tmp}/tando-bench-df.XXXXXX")
{ sed 's/^FROM ubuntu:\${UBUNTU}$/FROM ubuntu:${UBUNTU} AS base/' Dockerfile
  sed 's/^FROM tando-bench-base:latest$/FROM base AS docker/' Dockerfile.docker
  sed 's/^FROM tando-bench-base:latest$/FROM base AS podman/' Dockerfile.podman; } > "$f"
for t in base docker podman; do
  docker buildx build -q --builder tando-bench-img --load --target $t -t tando-bench-$t:latest -f "$f" . >/dev/null
  echo "built tando-bench-$t:latest"; done
rm -f "$f"
