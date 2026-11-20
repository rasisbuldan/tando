#!/bin/bash
# test/e2e-faults-q3.sh: sixth 3 of 6 of the fault scenarios: test/e2e-faults.sh --shard 3/6 (the
# default list cut into six chunks of about equal time, s00 first in each). A suite of its own for
# test/all.sh, on its own server, so the six shards run at once; q1..q6 together are exactly
# test/e2e-faults.sh. Work dir: T_WORK (test/all.sh sets one per suite), or test/.e2e-faults-q3-<server>.
set -u
: "${TANDO_TEST_SSH_PORT:-2222}"   # the server comes from the environment (test/all.sh reads this line)
FAULT_SUITE=e2e-faults-q3 exec "$(cd "$(dirname "$0")" && pwd -P)/e2e-faults.sh" --shard 3/6 "$@"
