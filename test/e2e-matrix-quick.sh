#!/bin/bash
# test/e2e-matrix-quick.sh: the fault matrix's cells of the defects fixed in milestone 1, for the
# node app, then the container app's switch failure (test/e2e-matrix.sh --cells; full and quick
# tiers, about 5 minutes). Everything else of the matrix runs only by name: test/all.sh --only
# e2e-matrix, or test/e2e-matrix.sh with its flags. Work dirs: T_WORK (test/all.sh sets one per
# suite) and T_WORK-container.
set -u
: "${TANDO_TEST_SSH_PORT:-2222}"   # the server comes from the environment (test/all.sh reads this line)
M=$(cd "$(dirname "$0")" && pwd -P)/e2e-matrix.sh rc=0
MATRIX_SUITE=quick "$M" --cells "$@" || rc=1
T_WORK=${T_WORK:+$T_WORK-container} MATRIX_SUITE=quick-container "$M" --kind container --cells "$@" || rc=1
exit $rc
