#!/bin/bash
# Remove everything the benchmark created on this machine: tando-bench-* containers (releasing
# their loop devices first), Kamal's local registry and buildx builder container, the bench
# registry and builder, the bench network, and images pulled or built for the benchmark.
# Never touches tando-testvm or anything else.
cd "$(dirname "$0")" && . ./lib.sh
for c in tando-bench-a tando-bench-b tando-bench-c tando-bench-d tando-bench-e; do stop_server $c; done
docker rm -f -v kamal-docker-registry tando-bench-registry buildx_buildkit_kamal-local-registry-docker-container0 \
  buildx_buildkit_tando-bench-builder0 >/dev/null 2>&1
docker buildx rm tando-bench-builder >/dev/null 2>&1; docker buildx rm tando-bench-img >/dev/null 2>&1   # their build caches go with them
docker rm -f -v buildx_buildkit_tando-bench-img0 >/dev/null 2>&1
docker volume rm buildx_buildkit_kamal-local-registry-docker-container0_state buildx_buildkit_tando-bench-builder0_state >/dev/null 2>&1
docker network rm tando-bench-net >/dev/null 2>&1
imgs=$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^(tando-bench-(base|docker|podman)|127\.0\.0\.1:5414/bench|localhost:5412/bench):')
imgs="$imgs $(docker image ls -q tando-bench-bare:24.04 >/dev/null && echo tando-bench-bare:24.04)"
# tando-bench-bare:26.04 is needed by run-a-tando.sh; ALL=1 removes it too
[ "${ALL:-0}" = 1 ] && imgs="$imgs tando-bench-bare:26.04"
[ "${KEEP_TOOL_IMAGES:-0}" = 1 ] || imgs="$imgs ghcr.io/basecamp/kamal:latest registry:3 moby/buildkit:buildx-stable-1"
for i in $imgs; do docker image rm "$i" >/dev/null 2>&1 && echo "removed image $i"; done
rm -rf .rc .copies .cache app/node_modules app/.next app/dist app/.tando app/.kamal/apps
docker ps -a --format '{{.Names}}' | grep -E 'tando-bench|kamal' ; docker volume ls -q | grep -E 'tando-bench|kamal|buildx' ; true
