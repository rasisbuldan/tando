#!/bin/bash
# test/race/setup.sh [--resnap] [--reset]: start the race server, snapshot the checkout (pinned CLI +
# agent under test), register it for laptops A and B, run host setup. Prints the agent's sha256.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
mkdir -p "$E"
reset=""
for a; do case $a in --resnap) rm -rf "${SNAP:?}";; --reset) reset=--reset;; esac; done
if [ ! -d "$SNAP" ]; then
  mkdir -p "$SNAP"
  (cd "$ROOT" && tar cf - bin lib server templates completions examples scripts VERSION install.sh 2> /dev/null) |
    (cd "$SNAP" && tar xf -)
fi
echo "agent sha256: $(shasum -a 256 "$SNAP/server/tando-agent" | cut -d' ' -f1)" | tee "$E/agent.sha256"
"$ROOT/test/server/up.sh" $reset >&2 || exit 1
for c in A B C; do
  [ -f "$E/cfg$c/hosts" ] || [ -d "$E/cfg$c" ] && continue
  TANDO_CONFIG_DIR=$E/cfg$c "$R" host add test vmadmin@127.0.0.1 --port "$TANDO_TEST_SSH_PORT" \
    --key "$ROOT/test/server/id_test" --yes >&2 || exit 1
done
rA host setup test public_port="$HP" >&2 || exit 1
srv 'sudo sha256sum /opt/tando/bin/tando-agent' | tee -a "$E/agent.sha256"
