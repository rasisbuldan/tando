#!/bin/bash
# ssh into the tando test server as vmadmin. Usage: test/server/ssh.sh [ssh-options] [command...]
D=$(cd "$(dirname "$0")" && pwd)
exec ssh -F /dev/null -i "$D/id_test" -p "${TANDO_TEST_SSH_PORT:-2222}" -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  vmadmin@127.0.0.1 "$@"
