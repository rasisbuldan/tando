#!/bin/bash
# test/e2e-matrix-weekly.sh: the fault matrix's weekly cells (test/e2e-matrix.sh --weekly) of the
# static, container, python, next and data kinds: where their code path differs from node's (docs/TESTING.md,
# "The fault matrix"). Each kind on its own server, one after the other (about 15 minutes). Known
# failures (MX_KNOWN in the driver) print as SKIP with their reason. nightly and weekly tiers.
# Work dirs: T_WORK (test/all.sh sets one per suite) and T_WORK-<kind>.
set -u
: "${TANDO_TEST_SSH_PORT:-2222}"   # the server comes from the environment (test/all.sh reads this line)
M=$(cd "$(dirname "$0")" && pwd -P)/e2e-matrix.sh
rc=0
for k in static container python next data; do
  T_WORK=${T_WORK:+$T_WORK-$k} MATRIX_SUITE=weekly-$k "$M" --kind "$k" --weekly "$@" || rc=1
done
exit $rc
