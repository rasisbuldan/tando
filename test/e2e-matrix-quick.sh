#!/bin/bash
# test/e2e-matrix-quick.sh: the fault matrix's cells of the defects fixed in milestone 1, for the
# node app, then two cells of the container app (its switch failure, a kill at its spawn), two
# of a static site (a kill at Caddy's file site, after the link moved), two of an app with
# workers and one of an app with a database (test/e2e-matrix.sh --cells; full and quick tiers,
# about 10 minutes). Everything else of the matrix runs only by name: test/all.sh --only
# e2e-matrix, or test/e2e-matrix.sh with its flags. Work dirs: T_WORK (test/all.sh sets one per
# suite), T_WORK-container, T_WORK-static, T_WORK-worker and T_WORK-data.
set -u
: "${TANDO_TEST_SSH_PORT:-2222}"   # the server comes from the environment (test/all.sh reads this line)
M=$(cd "$(dirname "$0")" && pwd -P)/e2e-matrix.sh rc=0
MATRIX_SUITE=quick "$M" --cells "$@" || rc=1
T_WORK=${T_WORK:+$T_WORK-container} MATRIX_SUITE=quick-container "$M" --kind container --cells "$@" || rc=1
T_WORK=${T_WORK:+$T_WORK-static} MATRIX_SUITE=quick-static "$M" --kind static --cells "$@" || rc=1
T_WORK=${T_WORK:+$T_WORK-worker} MATRIX_SUITE=quick-worker "$M" --kind worker --cells "$@" || rc=1
T_WORK=${T_WORK:+$T_WORK-data} MATRIX_SUITE=quick-data "$M" --kind data --cells "$@" || rc=1
exit $rc
