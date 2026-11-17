#!/bin/bash
# Build and start the tando test server (container tando-testvm). Idempotent.
# Usage: test/server/up.sh [--reset]    --reset: remove the container and start a clean one.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
# TANDO_TEST_CADDY=ubuntu builds with the distribution's older Caddy (2.6.2 on 26.04), as on the real VPS.
# Extra servers for parallel work: TANDO_TEST_NAME=tando-test-x TANDO_TEST_SSH_PORT=2301 TANDO_TEST_HTTP_PORT=8301
NAME=${TANDO_TEST_NAME:-tando-testvm} CADDY=${TANDO_TEST_CADDY:-upstream}
IMAGE=tando-testvm:latest; [ "$CADDY" = upstream ] || IMAGE=tando-testvm:caddy-$CADDY
# TANDO_TEST_BARE=1: a fresh VM (systemd, sshd, a sudo user; no Caddy, Node, rsync or curl)
BARE=${TANDO_TEST_BARE:-0}; [ "$BARE" = 1 ] && IMAGE=tando-testvm:bare
SSHP=${TANDO_TEST_SSH_PORT:-2222} HTTPP=${TANDO_TEST_HTTP_PORT:-8080}
READY=$D/.ready; [ "$NAME" = tando-testvm ] || READY=$D/.ready-$NAME
rm -f "$READY"
[ "${1:-}" = "--reset" ] && docker rm -f "$NAME" >/dev/null 2>&1 || true
# (several servers may start at once on a fresh checkout: make the key aside, the first link wins)
if [ ! -f "$D/id_test" ]; then
  ssh-keygen -q -t ed25519 -N '' -C tando-test -f "$D/.id_test.$$" &&
    { ln "$D/.id_test.$$.pub" "$D/id_test.pub" 2> /dev/null && ln "$D/.id_test.$$" "$D/id_test" 2> /dev/null; }
  rm -f "$D/.id_test.$$" "$D/.id_test.$$.pub"
  until [ -f "$D/id_test" ] && [ -f "$D/id_test.pub" ]; do sleep 0.2; done
fi

docker build -q --build-arg "CADDY=$CADDY" --build-arg "BARE=$BARE" -t "$IMAGE" "$D" >/dev/null
if ! docker container inspect "$NAME" >/dev/null 2>&1; then
  docker run -d --name "$NAME" --hostname "$NAME" --label tando.test=1 \
    --privileged --cgroupns=private \
    -p "127.0.0.1:$SSHP:22" -p "127.0.0.1:$HTTPP:80" ${TANDO_TEST_DOCKER_ARGS:-} "$IMAGE" >/dev/null
elif [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != true ]; then
  docker start "$NAME" >/dev/null
fi

# Install the test key (idempotent; survives docker restart).
docker exec -i "$NAME" sh -c 'install -d -m700 -o vmadmin -g vmadmin ~vmadmin/.ssh &&
  cat > ~vmadmin/.ssh/authorized_keys && chown vmadmin:vmadmin ~vmadmin/.ssh/authorized_keys &&
  chmod 600 ~vmadmin/.ssh/authorized_keys' < "$D/id_test.pub"

i=0
until "$D/ssh.sh" -o ConnectTimeout=2 true 2>/dev/null &&
      { [ "$BARE" = 1 ] || [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:$HTTPP/)" != 000 ]; }; do
  i=$((i + 1)); [ $i -lt 60 ] || { echo "up.sh: $NAME not ready after 60s" >&2; exit 1; }
  sleep 1
done
touch "$READY"
echo "$NAME ready: ssh vmadmin@127.0.0.1 -p $SSHP -i $D/id_test, http://<app>.localhost:$HTTPP"
