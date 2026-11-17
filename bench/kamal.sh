#!/bin/bash
# Run real Kamal 2 (ghcr.io/basecamp/kamal image) against bench/app. Host networking so Kamal's
# local registry (127.0.0.1:5412) and the server's ssh (127.0.0.1:2412) are reachable, and its
# reverse tunnel serves the registry to the server. Usage: VERSION=v1 bench/kamal.sh setup|deploy|...
B=$(cd "$(dirname "$0")" && pwd)
exec docker run --rm --network host -e VERSION="${VERSION:-}" \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$B/app:/workdir" \
  -v "$B/.key/id_bench:/keys/id_bench:ro" ghcr.io/basecamp/kamal@sha256:7b5be276aa17bbe122887f6a1ff12865f4848111989699b9786083be95d98415 "$@"   # 2.12.0
