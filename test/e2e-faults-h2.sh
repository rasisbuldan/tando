#!/bin/bash
# test/e2e-faults-h2.sh: half 2 of 2 of the fault scenarios, the list rotated by the day of the year
# first: test/e2e-faults.sh --shard 2/2 --rotate auto (so from night to night other scenarios are
# neighbours on a server; s00 first in each). A suite of its own for test/all.sh, on its own
# server; h1 and h2 together are exactly test/e2e-faults.sh. Work dir: T_WORK (test/all.sh sets
# one per suite), or test/.e2e-faults-h2-<server>.
set -u
: "${TANDO_TEST_SSH_PORT:-2222}"   # the server comes from the environment (test/all.sh reads this line)
FAULT_SUITE=e2e-faults-h2 exec "$(cd "$(dirname "$0")" && pwd -P)/e2e-faults.sh" --shard 2/2 --rotate auto "$@"
