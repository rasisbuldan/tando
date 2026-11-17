# shared by the attack scripts: env + helpers. exit 0 = attack blocked, 1 = attack succeeded, 2 = could not run
. /Users/you/tando/test/.work-sec2/env.sh
blocked() { echo "RESULT: BLOCKED - $*"; exit 0; }
succeeded() { echo "RESULT: SUCCEEDED - $*"; exit 1; }
inconclusive() { echo "RESULT: INCONCLUSIVE - $*"; exit 2; }
# run a command as alpha's scheduled job (the job runs $TANDO_DATA_DIR/jobcmd at :00/:20/:40); waits for it to start
# shellcheck disable=SC2034 # i only counts the tries
jobrun() { x "cat > \$TANDO_DATA_DIR/jobcmd <<'JOBEOF'
$1
JOBEOF
echo queued" > /dev/null; local i; for i in $(seq 1 30); do x 'test -e $TANDO_DATA_DIR/jobcmd' > /dev/null; x '[ -e $TANDO_DATA_DIR/jobcmd ] && echo w' | grep -q w || return 0; sleep 1; done; return 1; }
# put a file into alpha's shared/ (app-writable)
putshared() { curl -s -m 30 --data-binary @"$2" "http://alpha.localhost:$HP/__x" -H 'x: y' > /dev/null <<< ""; }
