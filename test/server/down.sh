#!/bin/bash
# Remove the tando test server container (the image is kept for fast restarts).
D=$(cd "$(dirname "$0")" && pwd)
NAME=${TANDO_TEST_NAME:-tando-testvm}
if [ "$NAME" = tando-testvm ]; then rm -f "$D/.ready"; else rm -f "$D/.ready-$NAME"; fi
docker rm -f "$NAME" >/dev/null 2>&1 || true
