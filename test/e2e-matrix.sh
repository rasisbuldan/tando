#!/bin/bash
# test/e2e-matrix.sh: the fault matrix (docs/TESTING.md "Fault matrix"; test/faults/lib-matrix.sh).
# For each operation, a trace of it without a fault lists the agent's fault points it passes;
# then, for each point and action, the operation runs with that one fault, recovery runs as on a
# server, and one checker asserts the invariants (eleven: the workers' with --kind worker). One PASS/FAIL line per cell:
#   <kind>/<op>/<verb>/<point>#<n>/<action>  [broken invariants]
#
#   test/e2e-matrix.sh                         node, every operation, kill fail reboot
#   test/e2e-matrix.sh --kind python           another kind of app: node next python static
#                                              container data (node + data dir, postgres, a job)
#   test/e2e-matrix.sh --ops deploy,rollback   these operations only (default: all of the kind)
#   test/e2e-matrix.sh --actions kill,fail     these actions only (default kill fail reboot; race:
#                                              a second client's configure, with other settings, at the point;
#                                              queue: a second client's deploy queues behind this one held at
#                                              the point, then this one is killed and recovered)
#   test/e2e-matrix.sh --quick                 the points most likely to hide a defect only
#   test/e2e-matrix.sh --points 'link|ra\.'    points matching this extended regex only
#   test/e2e-matrix.sh --shard 2/4             every 4th cell from the 2nd (after the traces)
#   test/e2e-matrix.sh --cells                 only the cells of the defects fixed in milestone 1
#                                              (CELLS below; container: the switch failure)
#   test/e2e-matrix.sh --ops deploy,rollback --actions kill --points '(^|/)(pre|post):'
#                                              a kill at every state write of a deploy and a rollback
#   test/e2e-matrix.sh --kind static --weekly  the weekly cells of that kind (WEEKLY_CELLS below: the
#                                              points where its path differs from node's)
#   test/e2e-matrix.sh --selftest              prove the checker: each invariant, broken on purpose
#   test/e2e-matrix.sh --list                  trace and print the cells; run none
# Operations: deploy, deploy-rel (a release command), deploy-bad (fails after the switch),
# deploy-pre (refused in the pre-flight), deploy-stopped (to a stopped app), rollback, restart,
# stop, start, env (env set), env-bad (an env that breaks the app: reverted), recover (a second
# fault inside the recovery of a first one).
# bash 3.2 compatible.
set -u
: "${TANDO_TEST_SSH_PORT:-2222}"   # the server comes from the environment (test/all.sh reads this line)
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
KIND=node OPS="" ACTIONS="kill fail reboot" QUICK=0 PTS="" SHARD="" SELFTEST=0 LIST=0 CELLSONLY=0 WEEKLY=0
while [ $# -gt 0 ]; do
  case $1 in
    --kind) KIND=${2:-}; shift;;
    --ops) OPS=$(printf '%s' "${2:-}" | tr ',' ' '); shift;;
    --actions) ACTIONS=$(printf '%s' "${2:-}" | tr ',' ' '); shift;;
    --quick) QUICK=1;;
    --points) PTS=${2:-}; shift;;
    --shard) SHARD=${2:-}; shift;;
    --selftest) SELFTEST=1;;
    --cells) CELLSONLY=1;;
    --weekly) CELLSONLY=1 WEEKLY=1;;
    --list) LIST=1;;
    *) echo "e2e-matrix: unknown argument \"$1\" (see the head of this file)" >&2; exit 2;;
  esac
  shift
done
case $KIND in node|next|python|static|container|data|worker) ;; *) echo "e2e-matrix: --kind node|next|python|static|container|data|worker" >&2; exit 2;; esac
SI=0 SK=0
case $SHARD in "") ;; *[!0-9/]*|*/*/*|/*|*/) echo "e2e-matrix: --shard i/K" >&2; exit 2;;
  */*) SI=$((10#${SHARD%/*})) SK=$((10#${SHARD#*/})); [ "$SI" -ge 1 ] && [ "$SI" -le "$SK" ] || exit 2;; esac
# the operations a kind has (static: no process to restart, stop or give an env; container: no
# release command; python, next, container, data: the paths that differ from node)
if [ -z "$OPS" ]; then
  case $KIND in
    node) OPS="deploy deploy-rel deploy-bad deploy-pre deploy-stopped rollback restart stop start env env-bad recover";;
    static) OPS="deploy deploy-pre rollback";;
    container) OPS="deploy deploy-bad rollback restart";;
    worker) OPS="deploy deploy-bad deploy-pre rollback restart stop start env recover";;
    *) OPS="deploy deploy-bad rollback restart";;
  esac
fi
t_init "e2e-matrix${MATRIX_SUITE:+-$MATRIX_SUITE}"
. "$ROOT/test/faults/lib-matrix.sh"
export TANDO_WAIT=1
A=mx$(printf '%s' "$KIND" | cut -c1-4) W=$E MXV=0
mkdir -p "$W/$A"; : > "$W/ids"; : > "$W/case.log"
CELLOUT=$E/cells.tsv; : > "$CELLOUT"
log "fault matrix: kind $KIND, operations: $OPS; actions: $ACTIONS${QUICK:+ (quick=$QUICK)}"

t_server_up --reset || exit 1
mx_markers || { fail "0 could not make the test markers on the server"; t_done; }
t_host_add > /dev/null 2>&1
setup_args="public_port=$T_HTTP_PORT"
[ "$KIND" = data ] && setup_args="$setup_args postgres=yes"
[ "$KIND" = container ] && setup_args="$setup_args podman=yes"
[ "$KIND" = python ] && setup_args="$setup_args python=yes"
"$R" host setup test $setup_args > "$E/setup.out" 2>&1 || { cat "$E/setup.out" >&2; fail "0 host setup"; t_done; }

# ---- the app's baseline: two verified releases, data, rows ------------------------------------
mx_seed() {
  dxs "runuser -u tando-$A -- sh -c 'echo seed-$RANDOM > /opt/tando/apps/$A/shared/data/sentinel'" 2>> "$W/case.log"
  if [ "$KIND" = data ]; then
    dxs "sudo -u postgres psql -X -q -d tando_$A -c 'create table if not exists mx(i int); insert into mx select generate_series(1, 50)'" >> "$W/case.log" 2>&1
  fi
}
mx_fresh() {
  log "fresh $A"
  if dx test -d "/opt/tando/apps/$A"; then echo "$A" | (cd "$W/$A" && "$R" destroy -a "$A" --purge > "$W/destroy.out" 2>&1); fi
  rm -f "$W/ids"; : > "$W/ids"
  MXV=$((MXV + 1)); mx_version "$MXV"
  mx_client "$W/d$MXV.out" up || { cat "$W/d$MXV.out" >&2; return 1; }
  mx_note_id "$(mx_rid "$W/d$MXV.out")" "$MXV"
  mx_deploy || { cat "$W/d$MXV.out" >&2; return 1; }
  mx_seed
}
mx_fresh || { fail "0 the baseline app could not be deployed"; t_done; }

# ---- one cell --------------------------------------------------------------------------------
# mx_killtree pid: the process and everything it started (a client left polling)
mx_killtree() { local c; for c in $(pgrep -P "$1" 2> /dev/null); do mx_killtree "$c"; done; kill "$1" 2> /dev/null; }
# the state an operation starts from, set up without a fault
mx_pre() {
  local st; mx_facts > /dev/null 2>&1; st=$(fv s_stopped)
  [ -z "$(fv env_bad)" ] || mx_client "$W/pre.out" env unset MX_BAD
  case $1 in
    start|deploy-stopped) [ -n "$st" ] || mx_client "$W/pre.out" stop || return 1;;
    *) [ -z "$st" ] || mx_client "$W/pre.out" start || return 1;;
  esac
  [ "$1" != rollback ] || mx_deploy || return 1
  return 0
}
# the operation itself (the client, as a user runs it): version MXV+1, env value e<MXE+1>
MXE=0
mx_go() {
  local v=$MXN
  case $1 in
    deploy|deploy-stopped|recover) mx_version "$v";;
    deploy-rel) MX_RELEASE="sleep 1" mx_version "$v";;
    deploy-bad) mx_version "$v" unhealthy@live;;
    deploy-pre) mx_version "$v" exit@pre;;
  esac
  case $1 in
    deploy*|recover) mx_client "$W/op.out" deploy;;
    rollback) mx_client "$W/op.out" rollback;;
    restart|stop|start) mx_client "$W/op.out" "$1";;
    env) mx_client "$W/op.out" env set "MXVAL=e$((MXE + 1))";;
    env-bad) mx_client "$W/op.out" env set MX_BAD=1;;
  esac
}
# the point where an operation has done what it was asked (after it, a kill must end in the new
# state, before it in the old one); none: the operation never changes what serves
mx_commit() {
  case $1 in
    deploy|deploy-rel|deploy-stopped|recover) echo "run-activation link.moved";;
    rollback) echo "rollback link.moved";;
    stop) echo "stop post:state";;
    start) echo "start post:state";;
    env) echo "env-set env.saved";;
    *) echo none;;
  esac
}
# expectations of a cell: phase before|after|none (the trace run: after), action
mx_expect() { # op phase action
  local op=$1 ph=$2 act=$3
  MX_WANT=old MX_RUN=running MX_ENVW=$MX_ENV0 MX_LOOP503=0
  case $op in
    deploy|deploy-rel|rollback|recover)
      [ "$ph" = after ] && MX_WANT=new
      [ "$act" = fail ] && [ "$ph" != none ] && MX_WANT=any;;
    deploy-stopped)
      MX_LOOP503=1
      if [ "$ph" = after ]; then MX_WANT=new; else MX_RUN=stopped; fi
      [ "$act" = fail ] && MX_WANT=any MX_RUN=any;;
    stop|start)
      MX_LOOP503=1
      local a=running b=stopped; [ "$op" = start ] && a=stopped b=running
      if [ "$ph" = after ]; then MX_RUN=$b; else MX_RUN=$a; fi
      [ "$act" = fail ] && MX_RUN=any;;
    env)
      [ "$ph" = after ] && MX_ENVW="e$((MXE + 1))"
      [ "$act" = fail ] && MX_ENVW="any:$MX_ENV0 e$((MXE + 1))";;
  esac
  [ "$op" = recover ] && [ "$ph" = after ] && MX_WANT=any
  MX_LOOPOK=1
}
mx_reset() {
  log "resetting $A after a failed cell"
  dxs "systemctl reset-failed 'tando-$A*' 2> /dev/null; true"
  # (one more try: the baseline is rebuilt from nothing, and a fresh image build or pull can fail once)
  mx_fresh || { log "the baseline failed once; trying again"; mx_fresh; } ||
    { fail "0 the baseline app could not be deployed again"; t_done; }
}
# Known failures: cells that fail today for a reason that is not a defect of the test, each with
# the invariants that break and why it stays. A listed cell that breaks exactly those invariants
# prints as SKIP "KNOWN ..." (it is counted, listed at the end, and the baseline is rebuilt); one that
# passes FAILS ("remove it from MX_KNOWN"); one that breaks anything else FAILS as any cell does.
# Lines: <glob of kind/op/verb/point#n/action> <broken invariants, e.g. " 6"> <reason>
MX_KNOWN=""
# mx_known <id>: the reason when the cell is listed, with its invariants in MX_KINV
mx_known() {
  local l g
  while IFS='|' read -r g MX_KINV l; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254  # (the glob in the list)
    case $1 in $g) MX_KREASON=$l; return 0;; esac
  done <<< "$MX_KNOWN"
  return 1
}
# mx_queued: two activations of the app run (one holds the lock, one waits for it)
mx_queued() {
  local n; n=$(dxs "systemctl list-units --plain --no-legend 'tando-$A-act-*' | grep -c ." 2> /dev/null)
  [ "${n:-0}" -ge 2 ] 2> /dev/null
}
# mx_cell <op> <verb> <point> <nth> <action> <phase> [second point for recover]: run one cell
NFAIL=0 NPASS=0 NSKIP=0 NKNOWN=0
mx_cell() {
  local op=$1 verb=$2 pt=$3 nth=$4 act=$5 ph=$6 p2=${7:-} id rel before t0 ov
  id="$KIND/$op/$verb/$pt#$nth/$act${p2:+/$p2}"
  [ "$pt" = - ] && id="$KIND/$op/trace"
  t0=$(date +%s)
  echo "==== $id" >> "$W/case.log"
  mx_spec_clear
  mx_pre "$op" >> "$W/case.log" 2>&1 || { fail "$id: could not prepare the operation (a deploy without a fault failed)"; mx_reset; return; }
  [ "${MX_TRACE:-0}" = 1 ] && mx_trace_on      # (the trace: the operation's own points, not its preparation's)
  mx_facts > /dev/null 2>&1
  MX_OLD=$(fv s_current) MX_H0=$(fv hist_n) MX_DATA0=$(fv data_sum) MX_DB0=$(fv db_rows) MX_ENV0=$(fv env_val)
  [ -n "$MX_ENV0" ] || MX_ENV0=""
  before=$(mx_releases) MX_NEW="" MX_OP=$op MX_REBOOT_T=0 MX_UP_T=0 MX_RACED="" MX_QUEUED=""
  if [ "$op" = rollback ]; then   # the newest verified release older than the current one
    MX_NEW=$(sed -n 's/^rel_\([^=]*\)=verified$/\1/p' "$W/facts" | grep -vx "$MX_OLD" | sort | tail -1)
  fi
  # the next version: its parity differs from the live one's (another health path and start
  # command), so a check or a restart that reaches the wrong release cannot pass by chance
  MXN=$((MXV + 1)) ov=$(mx_ver_of "$MX_OLD")
  [ -n "$ov" ] && [ $(( (MXN - ov) % 2 )) = 0 ] && MXN=$((MXN + 1))
  mx_expect "$op" "$ph" "$act"
  if [ "$pt" != - ]; then
    local a=$act; case $act in reboot|race|queue) a=hang;; esac
    mx_spec fault "$pt" "$a" "$nth" "$verb"
    [ -n "$p2" ] && mx_spec next "${p2#* }" "${MX_ACT2:-kill}" 1 "${p2%% *}"
  fi
  mx_loop_start
  # the operation in the background (a client that never returns is ended after 10 minutes)
  (mx_go "$op") >> "$W/case.log" 2>&1 &
  local cl=$! i=0
  if [ "$act" = reboot ]; then
    # (the point can come after the client has its answer: a refused deploy is told as soon as its
    # result is written, and the activation's last writes follow; wait while its unit lives too)
    while [ $i -lt 600 ] && ! dxs "test -e $MX_T/reached" 2> /dev/null &&
      { kill -0 $cl 2> /dev/null || ! mx_settled 2> /dev/null; }; do sleep 0.2; i=$((i + 1)); done
    if dxs "test -e $MX_T/reached" 2> /dev/null; then
      MX_REBOOT_T=$(date +%s)
      mx_reboot || { fail "$id: the server did not come back after the restart"; mx_loop_stop; return; }
      MX_UP_T=$(date +%s)
    fi
  fi
  if [ "$act" = race ]; then
    # a second client: its configure, with the next version's tando.conf (the other parity), runs
    # while this deploy waits at the point; then the deploy goes on
    while [ $i -lt 600 ] && ! dxs "test -e $MX_T/reached" 2> /dev/null && kill -0 $cl 2> /dev/null; do sleep 0.2; i=$((i + 1)); done
    if dxs "test -e $MX_T/reached" 2> /dev/null; then
      # (a configure that fails proves nothing: the cell then counts as not reached)
      mx_settings $((MXN + 1)) | dx /opt/tando/bin/tando-agent configure "$A" >> "$W/case.log" 2>&1 && MX_RACED=1 ||
        echo "  (the second client's configure failed)" >> "$W/case.log"
      dxs "touch $MX_T/release"
    fi
  fi
  local cl2="" MX_Q2RC=0
  if [ "$act" = queue ]; then
    # a second client deploys the version after (its own settings: the other parity) while this
    # one holds the app's lock at the point; once it is queued (a second activation unit runs),
    # this one's activation is killed: its recovery fails it, and the waiter runs after it
    while [ $i -lt 600 ] && ! dxs "test -e $MX_T/reached" 2> /dev/null && kill -0 $cl 2> /dev/null; do sleep 0.2; i=$((i + 1)); done
    if dxs "test -e $MX_T/reached" 2> /dev/null; then
      (mx_version $((MXN + 1)); mx_client "$W/op2.out" deploy) >> "$W/case.log" 2>&1 &
      cl2=$!
      if T_UNTIL_STEP=0.3 t_until 120 mx_queued; then
        MX_QUEUED=1
        # (this deploy's release: its client printed it when activate returned)
        dxs "systemctl kill -s KILL tando-$A-act-$(mx_rid "$W/op.out")" >> "$W/case.log" 2>&1
      else
        echo "  (the second deploy did not queue)" >> "$W/case.log"
      fi
      dxs "touch $MX_T/release"
    fi
  fi
  i=0; while kill -0 $cl 2> /dev/null && [ $i -lt 1200 ]; do sleep 0.5; i=$((i + 1)); done
  mx_killtree $cl; wait $cl 2> /dev/null
  if [ -n "$cl2" ]; then
    i=0; while kill -0 $cl2 2> /dev/null && [ $i -lt 1200 ]; do sleep 0.5; i=$((i + 1)); done
    mx_killtree $cl2; wait $cl2 2> /dev/null; MX_Q2RC=$?
  fi
  [ "$op" = env ] && MXE=$((MXE + 1))
  case $op in deploy*|recover) MXV=$MXN;; esac
  mx_wait_settled 240 || echo "  (not settled after 240 s)" >> "$W/case.log"
  mx_watcher
  mx_wait_settled 240
  mx_loop_stop
  cat "$W/op.out" >> "$W/case.log" 2> /dev/null
  local fired=1
  # (a reboot clears /run: there, reaching the point is what counts)
  if [ "$act" = reboot ]; then [ "$MX_REBOOT_T" != 0 ] || fired=0
  elif [ "$act" = race ]; then [ "${MX_RACED:-}" = 1 ] || fired=0
  elif [ "$act" = queue ]; then [ "${MX_QUEUED:-}" = 1 ] || fired=0
  elif [ "$pt" != - ]; then mx_fired || fired=0; fi
  mx_spec_clear
  # the operation's release: what the client printed, else one that appeared on disk or in history
  case $op in
    deploy*|recover)
      MX_NEW=$(mx_rid "$W/op.out")
      if [ -z "$MX_NEW" ]; then
        mx_facts > /dev/null 2>&1
        for rel in $(mx_releases) $(sed -n 's/^hist=\([^ ]*\) .*/\1/p' "$W/facts"); do
          case " $before " in *" $rel "*) ;; *) MX_NEW=$rel; break;; esac
        done
      fi
      [ -n "$MX_NEW" ] && mx_note_id "$MX_NEW" "$MXV";;
  esac
  if [ "$act" = queue ] && [ "$fired" = 1 ]; then
    # the waiter's release is the operation's: it must serve, verified, with its settings; the
    # killed one's line (failed) is one more history line before it
    MXV=$((MXN + 1)) MX_NEW=$(mx_rid "$W/op2.out") MX_WANT=new MX_H0=$((MX_H0 + 1))
    [ -n "$MX_NEW" ] && mx_note_id "$MX_NEW" "$MXV"
    cat "$W/op2.out" >> "$W/case.log" 2> /dev/null
  fi
  if [ "$fired" = 0 ]; then
    NSKIP=$((NSKIP + 1)); skip "$id not reached (the point was not passed this time)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\tskip\t\n' "$KIND" "$op" "$verb" "$pt#$nth" "$act" "$ph" >> "$CELLOUT"
    mx_inv > /dev/null 2>&1 || mx_reset
    return
  fi
  # (queue: the waiter's client must also say it succeeded)
  if [ "$MX_Q2RC" != 0 ]; then
    NFAIL=$((NFAIL + 1)); fail "$id: the queued deploy failed (exit $MX_Q2RC): $(tail -3 "$W/op2.out" | tr '\n' ' ')"
    mx_reset; return
  fi
  if mx_inv 2>> "$W/case.log"; then
    if mx_known "$id"; then
      NFAIL=$((NFAIL + 1)); fail "$id: listed in MX_KNOWN as a failure ($MX_KREASON) but it passes: remove it from the list"
      return
    fi
    NPASS=$((NPASS + 1)); pass "$id ($(( $(date +%s) - t0 )) s)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\tpass\t\n' "$KIND" "$op" "$verb" "$pt#$nth" "$act" "$ph" >> "$CELLOUT"
  elif mx_known "$id" && [ "$MX_BROKEN" = "$MX_KINV" ]; then
    NKNOWN=$((NKNOWN + 1)); skip "KNOWN failure $id:$(tr '\n' ';' < "$W/inv.out" | sed 's/;$//; s/;/ |/g') ($MX_KREASON)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\tknown\t%s\n' "$KIND" "$op" "$verb" "$pt#$nth" "$act" "$ph" "$(echo $MX_BROKEN)" >> "$CELLOUT"
    mx_reset
  else
    NFAIL=$((NFAIL + 1))
    fail "$id:$(tr '\n' ';' < "$W/inv.out" | sed 's/;$//; s/;/ |/g')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\tfail\t%s\n' "$KIND" "$op" "$verb" "$pt#$nth" "$act" "$ph" "$(echo $MX_BROKEN)" >> "$CELLOUT"
    { echo "  facts:"; sed 's/^/    /' "$W/facts"; echo "  client:"; tail -8 "$W/op.out" | sed 's/^/    /'; } >> "$W/case.log"
    mx_reset
  fi
}

# ---- the checker, proved: each invariant broken on purpose must be named --------------------------
if [ "$SELFTEST" = 1 ]; then
  st_case() { # n what setup-cmd undo-cmd
    local n=$1 what=$2
    mx_facts > /dev/null 2>&1
    MX_OP=restart MX_OLD=$(fv s_current) MX_NEW="" MX_H0=$(fv hist_n) MX_DATA0=$(fv data_sum) MX_DB0=$(fv db_rows)
    MX_ENV0=$(fv env_val); mx_expect restart none kill; MX_LOOPOK=0 MX_REBOOT_T=0
    mx_inv 2> /dev/null || { fail "S$n before breaking: the checker fails a sound app:$(tr '\n' ' ' < "$W/inv.out")"; return; }
    dxs "$3" >> "$W/case.log" 2>&1
    [ "$n" = 10 ] && { MX_LOOPOK=1; printf '200 0.1 1\n502 0.1 1\n' > "$W/loop"; MX_REQ=2; }
    mx_inv 2> /dev/null
    case " $MX_BROKEN " in
      *" $n "*) pass "S$n the checker names inv$n when $what ($(tr '\n' ' ' < "$W/inv.out" | cut -c1-160))";;
      *) fail "S$n the checker does not name inv$n when $what (it named:$MX_BROKEN)";;
    esac
    dxs "$4" >> "$W/case.log" 2>&1
    [ "$n" = 10 ] && : > "$W/loop"
    mx_facts > /dev/null 2>&1; MX_LOOPOK=0
    mx_inv 2> /dev/null || { log "S$n: the undo left:$MX_BROKEN; a fresh app"; mx_fresh; }
  }
  D=/opt/tando/apps/$A
  # lint: allow RL02 these run on the test server (GNU sed), through docker exec
  SEDI="sed -i"
  st_case 1 "the app's process is stopped behind tando's back" "systemctl stop tando-$A" "systemctl start tando-$A; sleep 2"
  st_case 2 "app.conf has the other version's health path" \
    "$SEDI 's|^health=/hc-|health=/hcx-|' $D/app.conf" "$SEDI 's|^health=/hcx-|health=/hc-|' $D/app.conf"
  st_case 3 "the live release is recorded bad" \
    "c=\$(sed -n 's/^current=//p' $D/state); $SEDI \"s/^status_\$c=verified/status_\$c=bad/\" $D/state" \
    "c=\$(sed -n 's/^current=//p' $D/state); $SEDI \"s/^status_\$c=bad/status_\$c=verified/\" $D/state"
  st_case 4 "history has a line no operation wrote" \
    "printf '1\\tx\\tdeploy\\tok\\n' >> $D/history.tsv" "$SEDI '\$d' $D/history.tsv"
  st_case 5 "the state is left in phase verify" "$SEDI 's/^phase=idle/phase=verify/' $D/state" "$SEDI 's/^phase=verify/phase=idle/' $D/state"
  st_case 6 "an upload lease is left" "printf 'token=x\\n' > $D/upload" "rm -f $D/upload"
  st_case 7 "only the live release is left on disk" \
    "mkdir -p /root/mxkeep; c=\$(sed -n 's/^current=//p' $D/state); for r in $D/releases/*; do [ \${r##*/} = \$c ] || mv \$r /root/mxkeep/; done" \
    "mv /root/mxkeep/* $D/releases/"
  st_case 8 "the state says stopped while the unit runs" \
    "$SEDI 's/^phase=idle/phase=idle\\nstopped=1/' $D/state" "$SEDI '/^stopped=1/d' $D/state"
  st_case 9 "the data sentinel changed" \
    "cp -p $D/shared/data/sentinel /root/mxsent; echo changed >> $D/shared/data/sentinel" "cp -p /root/mxsent $D/shared/data/sentinel"
  st_case 10 "a visitor got a 502" ":" ":"
  if [ "$KIND" = worker ]; then
    st_case 11 "a worker of the live release is stopped behind tando's back" \
      "systemctl stop tando-${A}_worker-a" "systemctl start tando-${A}_worker-a; sleep 1"
    st_case 11 "a worker the live release does not have runs" \
      "sed 's/^Description=.*/Description=stray/' /etc/systemd/system/tando-${A}_worker-a.service > /etc/systemd/system/tando-${A}_worker-z.service; systemctl daemon-reload; systemctl start tando-${A}_worker-z" \
      "systemctl stop tando-${A}_worker-z; rm -f /etc/systemd/system/tando-${A}_worker-z.service; systemctl daemon-reload; systemctl reset-failed tando-${A}_worker-z 2> /dev/null; true"
  fi
  t_done
fi

# ---- the cells of milestone 1's defects (one each; docs/TESTING.md "The fault matrix") ------------
# defect op verb point nth action phase. a: a failure after the link moved goes back; b: a crash
# between the link swap and the state write; c: start and health of the serving release; d: a
# stopped app stays stopped; e: a reservation that never ran; f: an operation's end cut short.
# Milestone 2a: g: two clients with different settings (the other's configure lands between this
# deploy's configure and its activation); h: a deploy refused or cut off before the switch leaves
# the live app's unit file and Caddy site as they were (configure no longer changes them); i: job
# units that could not be written are not counted done (recovery writes them)
CELLS="
a deploy run-activation ra.restart 1 fail after
a rollback rollback ra.restart 1 fail after
a deploy-bad run-activation ra.restart 2 fail after
b deploy run-activation link.moved 1 kill after
b deploy run-activation link.moved 1 reboot after
b rollback rollback link.moved 1 kill after
c rollback - - 0 none after
c deploy run-activation imp.cp 1 kill before
d deploy-stopped run-activation imp.cp 1 kill before
e deploy activate act.spawn 1 kill before
e deploy run-activation run.locked 1 kill before
f deploy run-activation deploy.jobs 1 kill after
f rollback rollback rollback.hist 1 fail after
g deploy activate act.mkdir 1 race after
h deploy-pre - - 0 none after
h deploy run-activation pre.stop 1 kill before
i deploy run-activation deploy.jobs 1 fail after
i deploy run-activation jobs.write 1 fail after
e deploy run-activation run.queue 1 fail before
j stop stop caddy.mv 1 fail after
k rollback rollback post:activation 1 kill before
l deploy begin post:upload 1 kill before
l deploy activate act.mkdir 1 kill before
q deploy run-activation imp.cp 1 queue before"
# k: a rollback killed after its progress file (result=running) and before its first state write: tando-watch's recover-all
# (srv/watch/pretick.go rollbackCut) ends it; nothing did before
# the other kinds: one or two cells where their path differs from node's (a static site has no
# process: Caddy's file site is the switch; a container has a spawn and a stop of its own)
case $KIND in
  container) CELLS="
a deploy run-activation ra.restart 1 fail after
c deploy run-activation pre.spawn 1 kill before";;
  static) CELLS="
b deploy run-activation sw.caddy_up 1 kill before
b deploy run-activation link.moved 1 kill after";;
  # workers (kind worker): a kill when the web process passed its check and the workers are about
  # to follow; going back after a failed check, the old workers could not be started at once
  worker) CELLS="
w deploy run-activation wk.start 1 kill after
w deploy-bad run-activation bad.workers 1 fail after";;
esac
# --weekly: more cells of the other kinds, chosen from a full run of each kind's grid (docs/TESTING.md,
# "The fault matrix"): the points where the kind's code path differs from node's, with the actions
# that found something or guard a switch. The cells of the milestone's defects (above) are in node's.
case $KIND in
  static) WEEKLY_CELLS="
s deploy run-activation sw.caddy_up 1 kill before
s deploy run-activation sw.caddy_up 1 fail before
s deploy run-activation link.mv 1 kill before
s deploy run-activation link.moved 1 kill after
s deploy run-activation link.moved 1 reboot after
s deploy run-activation fin.verify 1 fail after
s deploy run-activation deploy.hist 1 kill after
s deploy-pre run-activation deploy.drop 1 kill none
s deploy-pre run-activation imp.cp 1 kill none
s rollback rollback link.mv 1 kill before
s rollback rollback link.moved 1 kill after
s rollback rollback post:activation 1 kill before
s rollback rollback pre:activation 4 fail after
s rollback rollback rollback.hist 1 fail after";;
  container) WEEKLY_CELLS="
c deploy run-activation pre.spawn 1 kill before
c deploy run-activation pre.stop 1 kill before
c deploy run-activation ra.restart 1 fail after
c deploy run-activation sw.caddy_up 1 kill before
c deploy run-activation link.moved 1 kill after
c deploy run-activation link.moved 1 reboot after
c deploy run-activation fin.soak 1 kill after";;
  python) WEEKLY_CELLS="
p deploy run-activation imp.cp 1 kill before
p deploy run-activation pre.stop 1 kill before
p deploy run-activation ra.restart 1 fail after
p deploy run-activation link.moved 1 kill after
p deploy run-activation fin.verify 1 fail after
p deploy-bad run-activation ra.restart 2 fail after";;
  next) WEEKLY_CELLS="
n deploy run-activation imp.cp 1 kill before
n deploy run-activation pre.stop 1 kill before
n deploy run-activation ra.restart 1 fail after
n deploy run-activation link.moved 1 kill after
n deploy run-activation fin.verify 1 fail after
n deploy-bad run-activation ra.restart 2 fail after";;
  *) WEEKLY_CELLS="";;
esac
[ "$WEEKLY" = 0 ] || CELLS=$WEEKLY_CELLS
CELLS=${MX_CELLS:-$CELLS}     # (another list: MX_CELLS, same columns)
if [ "$CELLSONLY" = 1 ]; then
  while read -r d op v p n act ph <&3; do
    [ -n "$d" ] || continue
    if [ "$LIST" = 1 ]; then echo "$d: $op $v $p#$n $act ($ph)"; continue; fi
    if [ "$p" = - ]; then mx_cell "$op" - - 0 none after < /dev/null; else mx_cell "$op" "$v" "$p" "$n" "$act" "$ph" < /dev/null; fi
  done 3<<< "$CELLS"
  [ "$LIST" = 1 ] && exit 0
  log "matrix $KIND cells: $NPASS passed, $NFAIL failed, $NKNOWN known failures, $NSKIP not reached"
  t_done
fi

# ---- the cells -----------------------------------------------------------------------------------
# quick: the places the audits ranked highest (around the switch, the end of a verify, the
# rollback, recovery's own writes, the env and stop/start commits)
QRE='link\.|ra\.restart|fin\.(verify|soak)|bad\.|(deploy|rollback)\.hist|rb\.switch|sw\.backup|run\.locked|imp\.cp|pre\.stop|env\.(saved|verify)|svc\.|rec/(finish|switch|pre_stop)|act\.spawn'
points_of() { # op: trace it (a cell without a fault), write "verb point nth phase" per point passed
  local op=$1 c
  mx_spec_clear
  MX_TRACE=1 mx_cell "$op" - - 0 none after
  mx_trace_off | awk -v a="$A" '$2 == a { k = $1 " " $3; n[k]++; if ($3 ~ /fin\.soak$/ && n[k] > 1) next; print $1, $3, n[k] }' > "$W/trace.$op"
  c=$(mx_commit "$op")
  awk -v c="$c" 'BEGIN { ph = "before" } c != "none" && ($1 " " $2) == c && !seen { ph = "after"; seen = 1 }
    { print $0, (c == "none" ? "none" : ph) }' "$W/trace.$op" > "$W/points.$op"
}
N=0
for op in $OPS; do
  if [ "$op" = recover ]; then
    # first faults: a kill in each phase of a deploy; second: each point of the recovery that follows
    for first in "run-activation imp.cp" "run-activation pre.stop" "run-activation link.moved" "run-activation fin.verify" "run-activation fin.soak"; do
      ph=before; case ${first#* } in link.moved|fin.*) ph=after;; esac
      mx_spec_clear
      MX_TRACE=1 mx_cell deploy "${first%% *}" "${first#* }" 1 kill "$ph"
      mx_trace_off | awk -v a="$A" '$2 == a && $1 == "recover" { k = $1 " " $3; n[k]++; if (n[k] == 1) print $1, $3 }' > "$W/trace.rec"
      while read -r v p <&3; do
        for act2 in kill fail; do
          N=$((N + 1)); [ "$SK" = 0 ] || [ $(( (N - 1) % SK + 1 )) = "$SI" ] || continue
          [ -z "$PTS" ] || printf '%s\n' "$p" | grep -Eq "$PTS" || continue
          [ "$QUICK" = 0 ] || printf '%s\n' "$p" | grep -Eq "$QRE" || continue
          if [ "$LIST" = 1 ]; then echo "recover: ${first#* } then $v $p $act2"; continue; fi
          MX_ACT2=$act2 mx_cell recover "${first%% *}" "${first#* }" 1 kill "$ph" "$v $p" < /dev/null
        done
      done 3< "$W/trace.rec"
    done
    continue
  fi
  points_of "$op"
  log "$op: $(grep -c . "$W/points.$op") points"
  # (the list on fd 3: a cell's docker exec -i reads stdin)
  while read -r v p n ph <&3; do
    for act in $ACTIONS; do
      N=$((N + 1)); [ "$SK" = 0 ] || [ $(( (N - 1) % SK + 1 )) = "$SI" ] || continue
      [ -z "$PTS" ] || printf '%s\n' "$p" | grep -Eq "$PTS" || continue
      [ "$QUICK" = 0 ] || printf '%s\n' "$p" | grep -Eq "$QRE" || continue
      # a fail at a post: point is a no-op (the write is done); a reboot (a kill, then the boot's
      # recovery) at the state writes and the named points, not at the progress file's or a lease's
      case $act:$p in fail:post:*|fail:*/post:*) continue;; esac
      case $act:$p in reboot:*pre:activation|reboot:*post:activation|reboot:*:upload|reboot:*:app.conf) continue;; esac
      if [ "$act" = reboot ] && [ "$QUICK" = 1 ]; then printf '%s\n' "$p" | grep -Eq 'link\.|post:state|fin\.soak' || continue; fi
      if [ "$LIST" = 1 ]; then echo "$op $v $p#$n $act ($ph)"; continue; fi
      mx_cell "$op" "$v" "$p" "$n" "$act" "$ph" < /dev/null
    done
  done 3< "$W/points.$op"
done
[ "$LIST" = 1 ] && exit 0
# a plain deploy at the end: the last cell left a state the next deploy works on
mx_spec_clear
if mx_deploy && mx_facts > /dev/null 2>&1 && [ "$(mx_served_ver)" = "$MXV" ]; then pass "Z a plain deploy after the last cell goes live"
else fail "Z a plain deploy after the last cell does not go live (rc=$MXRC, serves $(mx_served_ver))"; fi
log "matrix $KIND: $NPASS cells passed, $NFAIL failed, $NKNOWN known failures, $NSKIP not reached"
t_done
