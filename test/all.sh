#!/bin/bash
# test/all.sh: run every test suite, in parallel where it is safe, each on its own test server.
#
#   test/all.sh                      ui-test, lint, go, install-test, e2e, e2e-next and every other test/e2e-*.sh
#   test/all.sh --only e2e,lint      just these suites (names without .sh)
#   test/all.sh --skip e2e-next      all but these
#   test/all.sh --repeat 3           run everything 3 times and report checks that do not pass
#                                    every time (flaky), with their logs
#   test/all.sh --portability        also run test/portability.sh
#   test/all.sh --as-is              run the hard-coded suites unmodified, one after the other, on
#                                    tando-testvm (2222/8080), the way a person runs them by hand
#   test/all.sh --fast               (accepted; hard-coded suites now always run in parallel)
#   test/all.sh --keep               leave the test servers running afterwards
#   test/all.sh --list               show the suites and how each would run
#   test/all.sh --report DIR         print the summary (and flaky checks) of an earlier run's logs
#   test/all.sh --allow-skip         a suite whose checks were all SKIP does not fail the run
#                                    (also TANDO_ALLOW_SKIP=1)
#
# Suites that follow docs/TESTING.md (read TANDO_TEST_NAME / TANDO_TEST_SSH_PORT /
# TANDO_TEST_HTTP_PORT, or source test/lib.sh) run in parallel, each on its own server slot.
# Suites that still hard-code tando-testvm, 2222 and 8080 run from a copy in .tando/ in which those
# three are replaced by the slot's name and ports, so they never touch a server someone else is
# using.
# Servers: every server suite has its own test server, never shared with another suite (a server
# keeps the apps a suite left, which the next suite would trip over): ${TANDO_ALL_PREFIX:-tando-test-q}<n>
# with ssh port ${TANDO_ALL_SSH_BASE:-2310}+n and http ${TANDO_ALL_HTTP_BASE:-8310}+n, where n is the
# suite's place among all server suites (the same n with --only/--skip). A suite that uses a second
# server (TANDO_TEST_NAME2) gets <name>b on ports +50. At most ${TANDO_ALL_SLOTS:-4} server suites run
# at once; a suite's server is created when it starts and removed when it ends (unless --keep).
# A suite marked "# all.sh: own-server" creates its server itself (all.sh only picks its name and
# ports). The plan is checked first: two suites that would share a name or a port stop the run.
# Logs: .tando/all/<run>/[round-<r>/]<suite>.log (git-ignored); .tando/all/latest links the last run.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
cd "$ROOT" || exit 2
. "$ROOT/lib/ui.sh"

PREFIX=${TANDO_ALL_PREFIX:-tando-test-q}
SSH_BASE=${TANDO_ALL_SSH_BASE:-2310} HTTP_BASE=${TANDO_ALL_HTTP_BASE:-8310}
NSLOTS=${TANDO_ALL_SLOTS:-4}
repeat=1 only="" skipl="" keep=0 list=0 asis=0 porta=0 report="" allow_skip=${TANDO_ALLOW_SKIP:-0}

while [ $# -gt 0 ]; do
  case $1 in
    --repeat) repeat=${2:-}; shift
      case $repeat in ""|*[!0-9]*|0) echo "all: --repeat needs a number" >&2; exit 2;; esac;;
    --only) only=,${2:-},; shift;;
    --skip) skipl=,${2:-},; shift;;
    --keep) keep=1;;
    --list) list=1;;
    --as-is) asis=1;;
    --fast) ;;   # accepted for old scripts: every suite has its own server now
    --portability) porta=1;;
    --allow-skip) allow_skip=1;;
    --report) report=${2:-}; shift
      [ -d "$report" ] || { echo "all: --report needs a run directory (.tando/all/<run>)" >&2; exit 2; }
      report=$(cd "$report" && pwd -P);;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) echo "all: unknown argument $1" >&2; exit 2;;
  esac
  shift
done

# ---- suites -----------------------------------------------------------------------------------

# kind <file>: local (no server), param (follows the convention), fixed (hard-coded tando-testvm),
# pinned (hard-codes another server: skipped, it would reset a server all.sh does not own)
suite_kind() {
  case ${1##*/} in
    ui-test.sh|lint.sh|go.sh|install-test.sh|portability.sh) echo local; return;;
  esac
  # param: reads the server from the environment with a default (or uses test/lib.sh)
  local code
  code=$(grep -v '^[[:space:]]*#' "$1")   # usage comments do not count
  if printf '%s\n' "$code" | grep -q '\${TANDO_TEST_SSH_PORT:-\|^[[:space:]]*t_init[[:space:]]'; then echo param
  # pinned: assigns its own server name/port outright; all.sh cannot move it, so it is skipped
  elif printf '%s\n' "$code" | grep -qE '(^|[[:space:]])TANDO_TEST_(NAME|SSH_PORT)=[A-Za-z0-9]'; then echo pinned
  else echo fixed; fi
}

# every suite there is, in a fixed order: a server suite's number n is its place among the server
# suites of this list, so it is the same whatever --only/--skip select
ALL=()
for f in test/ui-test.sh test/lint.sh test/go.sh test/install-test.sh test/e2e.sh test/e2e-next.sh test/e2e-*.sh test/portability.sh; do
  [ -f "$f" ] || continue
  n=${f##*/}; n=${n%.sh}
  case " ${ALL[*]+${ALL[*]}} " in *" $n "*) continue;; esac
  ALL+=("$n")
done
SUITES=()
for n in ${ALL[@]+"${ALL[@]}"}; do
  case $n in portability) [ "$porta" = 1 ] || continue;; esac
  case $only in "") ;; *",$n,"*) ;; *) continue;; esac
  case $skipl in *",$n,"*) continue;; esac
  SUITES+=("$n")
done
[ ${#SUITES[@]} -gt 0 ] || { echo "all: no suites selected" >&2; exit 2; }

# plan: every suite gets a mode (local | param | fixed | pinned) and a server number (0 = none)
PLAN_MODE=() PLAN_SLOT=()
k=0 SLOT_OF=" "
for n in ${ALL[@]+"${ALL[@]}"}; do
  m=$(suite_kind "test/$n.sh")
  case $m:$n in local:portability|param:*|fixed:*) k=$((k + 1)); SLOT_OF="$SLOT_OF$n=$k ";; esac
done
for n in "${SUITES[@]}"; do
  m=$(suite_kind "test/$n.sh") s=${SLOT_OF##* "$n"=}; s=${s%% *}
  case $m in
    pinned) s=0;;
    local) [ "$n" = portability ] || s=0;;
    fixed) [ "$asis" = 1 ] && s=0;;
  esac
  PLAN_MODE+=("$m") PLAN_SLOT+=("$s")
done
case $NSLOTS in ""|*[!0-9]*|0) echo "all: TANDO_ALL_SLOTS must be a number of 1 or more" >&2; exit 2;; esac

slot_name() { echo "$PREFIX$1"; }
slot_ssh() { echo $((SSH_BASE + $1)); }
slot_http() { echo $((HTTP_BASE + $1)); }
# a suite's second server (suites that read TANDO_TEST_NAME2): <name>b, ports +50
uses_b() { grep -q 'TANDO_TEST_NAME2' "test/$1.sh"; }
own_server() { grep -q '^# all.sh: own-server' "test/$1.sh"; }
slot_servers() { # index: "name ssh http" per server the suite uses
  local s=${PLAN_SLOT[$1]}
  echo "$(slot_name "$s") $(slot_ssh "$s") $(slot_http "$s")"
  uses_b "${SUITES[$1]}" && echo "$(slot_name "$s")b $((SSH_BASE + 50 + s)) $((HTTP_BASE + 50 + s))"
  return 0
}
how() { # index
  local m=${PLAN_MODE[$1]} s=${PLAN_SLOT[$1]}
  local wd=""
  case $m in param|fixed) grep -q 'T_WORK\|^[[:space:]]*t_init[[:space:]]' "test/${SUITES[$1]}.sh" ||
    wd="; WARNING fixed work dir, clobbers (and is clobbered by) another run of it";; esac
  case $m:$s in
    pinned:*) echo "SKIPPED: sets TANDO_TEST_NAME/PORT itself (would reset a server all.sh does not own)";;
    local:0) echo "local, first: parallel, before any server suite starts";;
    local:*) echo "own server $(slot_name "$s") ($(slot_ssh "$s")/$(slot_http "$s"))";;
    param:*) echo "own server $(slot_name "$s") ($(slot_ssh "$s")/$(slot_http "$s"))$(uses_b "${SUITES[$1]}" &&
      echo " + $(slot_name "$s")b ($((SSH_BASE + 50 + s))/$((HTTP_BASE + 50 + s)))")$wd";;
    fixed:0) echo "as is, sequential on tando-testvm (2222/8080)";;
    fixed:*) echo "patched copy on own server $(slot_name "$s") ($(slot_ssh "$s")/$(slot_http "$s"))$wd";;
  esac
}

# no two suites may share a server or a port: fail fast, before anything starts
check_plan() {
  local i=0 n seen=" " name ssh http key
  for n in "${SUITES[@]}"; do
    if [ "${PLAN_SLOT[$i]}" != 0 ]; then
      while read -r name ssh http; do
        for key in "name:$name" "port:$ssh" "port:$http"; do
          case $key in port:*) [ "${key#port:}" -ge 1 ] && [ "${key#port:}" -le 65535 ] ||
            { echo "all: $n: port ${key#port:} is out of range (TANDO_ALL_SSH_BASE/HTTP_BASE)" >&2; return 1; };; esac
          case $seen in *" $key="*)
            local o=${seen##* "$key"=}; o=${o%% *}
            echo "all: suites $o and $n would share a test server (${key%%:*} ${key#*:});" \
              "every server suite needs its own: check TANDO_ALL_SSH_BASE/TANDO_ALL_HTTP_BASE" >&2
            return 1;;
          esac
          seen="$seen$key=$n "
        done
      done < <(slot_servers "$i")
    fi
    i=$((i + 1))
  done
}
check_plan || exit 2

if [ "$list" = 1 ]; then
  i=0
  for n in "${SUITES[@]}"; do printf '%-14s %s\n' "$n" "$(how $i)"; i=$((i + 1)); done
  exit 0
fi

# drop the pinned suites (shown by --list); a --report has nothing to plan
S2=() M2=() L2=()
i=0
for n in "${SUITES[@]}"; do
  if [ "${PLAN_MODE[$i]}" = pinned ]; then
    [ -n "$report" ] || echo "all: skipping $n: it sets its own test server (see docs/TESTING.md, conventions)" >&2
  else
    S2+=("$n") M2+=("${PLAN_MODE[$i]}") L2+=("${PLAN_SLOT[$i]}")
  fi
  i=$((i + 1))
done
[ ${#S2[@]} -gt 0 ] || { echo "all: no suites left to run" >&2; exit 2; }
SUITES=("${S2[@]}") PLAN_MODE=(${M2[@]+"${M2[@]}"}) PLAN_SLOT=(${L2[@]+"${L2[@]}"})


# ---- servers ----------------------------------------------------------------------------------

CREATED=""
port_busy() { (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null; }
# claim_servers: before anything starts, every server this run will create must be free: no
# container of that name yet (then it is ours: CREATED, suites may reset it) and nothing on its
# ports. An existing container of that name (an earlier run of ours with --keep) is reused, not reset.
claim_servers() {
  local i=0 n name ssh http
  for n in "${SUITES[@]}"; do
    if [ "${PLAN_SLOT[$i]}" != 0 ]; then
      while read -r name ssh http; do
        docker container inspect "$name" > /dev/null 2>&1 && continue
        if port_busy "$ssh" || port_busy "$http"; then
          echo "all: $n: port $ssh or $http is in use by something else; set TANDO_ALL_SSH_BASE/HTTP_BASE" >&2
          return 1
        fi
        CREATED="$CREATED $name"
      done < <(slot_servers "$i")
    fi
    i=$((i + 1))
  done
}
# slot_up <server number> <log>: create the suite's server if needed (the suites reset it themselves)
slot_up() {
  TANDO_TEST_NAME=$(slot_name "$1") TANDO_TEST_SSH_PORT=$(slot_ssh "$1") TANDO_TEST_HTTP_PORT=$(slot_http "$1") \
    "$ROOT/test/server/up.sh" > "$2" 2>&1
}
# slot_down <index>: remove the suite's servers that this run created (unless --keep)
slot_down() {
  local name ssh http
  [ "$keep" = 1 ] && return 0
  while read -r name ssh http; do
    case " $CREATED " in *" $name "*) TANDO_TEST_NAME=$name "$ROOT/test/server/down.sh" > /dev/null 2>&1;; esac
  done < <(slot_servers "$1")
}
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do
    [ -n "$p" ] && kill -0 "$p" 2> /dev/null && { pkill -TERM -P "$p" 2> /dev/null; kill "$p" 2> /dev/null; }
  done
  if [ "$keep" = 0 ] && [ -n "$CREATED" ]; then
    for p in $CREATED; do
      TANDO_TEST_NAME=$p "$ROOT/test/server/down.sh" > /dev/null 2>&1
    done
  fi
  [ "${LOCKED:-0}" = 1 ] && rm -rf "${LOCK:?}"
  ui_frame_cleanup 2> /dev/null
}
trap cleanup EXIT
trap 'echo; echo "all: interrupted" >&2; exit 130' INT TERM

# one run at a time per slot prefix: two runs would reset each other's slot containers mid-suite
LOCK=${TMPDIR:-/tmp}/tando-all-$(id -u)-$PREFIX.lock
if [ -z "$report" ]; then
  if ! mkdir "$LOCK" 2> /dev/null; then
    lp=$(cat "$LOCK/pid" 2> /dev/null)
    if [ -n "$lp" ] && kill -0 "$lp" 2> /dev/null; then
      echo "all: another test/all.sh (pid $lp) is using the $PREFIX<n> slots; wait for it," \
        "or use other slots: TANDO_ALL_PREFIX=... TANDO_ALL_SSH_BASE=... TANDO_ALL_HTTP_BASE=..." >&2
      exit 2
    fi
    rm -rf "${LOCK:?}" && mkdir "$LOCK" || exit 2   # left by a run that died
  fi
  echo $$ > "$LOCK/pid"
  LOCKED=1
fi

if [ -z "$report" ]; then
  RUN=$ROOT/.tando/all/$(date +%Y%m%d-%H%M%S)
  mkdir -p "$RUN"
  ln -sfn "$RUN" "$ROOT/.tando/all/latest"
else
  # an earlier run: its suites and rounds come from the files it left
  RUN=$report
  repeat=$(find "$RUN" -maxdepth 1 -type d -name 'round-*' | wc -l | tr -d ' ')
  if [ "$repeat" = 0 ]; then repeat=1 d=$RUN; else d=$RUN/round-1; fi
  SUITES=()
  for f in "$d"/*.rc; do [ -f "$f" ] && { f=${f##*/}; SUITES+=("${f%.rc}"); }; done
  [ ${#SUITES[@]} -gt 0 ] || { echo "all: no results in $RUN" >&2; exit 2; }
fi

# ---- running ----------------------------------------------------------------------------------

clock() { perl -MTime::HiRes=time -e 'printf "%.1f\n", time'; }
T0=$(clock)

# start <index> <outdir>: run one suite in the background; writes <suite>.log and <suite>.rc
PIDS=()
start() {
  local i=$1 out=$2 n=${SUITES[$1]} m=${PLAN_MODE[$1]} s=${PLAN_SLOT[$1]} f
  f=$ROOT/test/$n.sh
  (
    t=$(clock)
    if [ "$s" != 0 ]; then
      export TANDO_TEST_NAME TANDO_TEST_SSH_PORT TANDO_TEST_HTTP_PORT
      # resets are allowed only on containers this run created
      case " $CREATED " in *" $(slot_name "$s") "*) export TANDO_TEST_OWNED=1;; *) unset TANDO_TEST_OWNED;; esac
      export T_WORK=$ROOT/test/.all-$PREFIX-$n   # per suite and slot prefix: two all.sh runs never share one
      TANDO_TEST_NAME=$(slot_name "$s") TANDO_TEST_SSH_PORT=$(slot_ssh "$s")
      TANDO_TEST_HTTP_PORT=$(slot_http "$s")
      if uses_b "$n"; then
        export TANDO_TEST_NAME2=${TANDO_TEST_NAME}b TANDO_TEST_SSH_PORT2=$((SSH_BASE + 50 + s))
        export TANDO_TEST_HTTP_PORT2=$((HTTP_BASE + 50 + s))
      fi
      if [ "$m" != fixed ] || [ "$asis" = 0 ]; then
        if ! own_server "$n" && ! slot_up "$s" "$out/server-$n.log"; then
          { echo "FAIL 0 all.sh could not start $TANDO_TEST_NAME:"; tail -5 "$out/server-$n.log"; } > "$out/$n.log"
          echo "1 0" > "$out/$n.rc"; slot_down "$i"; exit 0
        fi
      fi
    fi
    if [ "$m" = fixed ] && [ "$s" != 0 ]; then
      # a copy one level below the repo root, so its ROOT=$(dirname $0)/.. is still the repo
      f=$ROOT/.tando/all-$n.sh
      perl -pe "s/\\btando-testvm\\b/$TANDO_TEST_NAME/g; s/(?<![0-9])2222(?![0-9])/$TANDO_TEST_SSH_PORT/g;
                s/(?<![0-9])8080(?![0-9])/$TANDO_TEST_HTTP_PORT/g" "$ROOT/test/$n.sh" > "$f"
      chmod +x "$f"
    fi
    case $n in
      ui-test) BASH_BIN=${BASH_BIN:-/bin/bash} /bin/bash "$f";;
      *) /bin/bash "$f";;
    esac > "$out/$n.log" 2>&1 < /dev/null
    rc=$?
    [ "$s" != 0 ] && slot_down "$i"
    echo "$rc $(awk -v a="$t" -v b="$(clock)" 'BEGIN { printf "%.1f", b - a }')" > "$out/$n.rc"
  ) &
  PIDS[$1]=$!
}

# counts <log> -> "pass fail skip" (PASS/FAIL lines; ui-test and lint print their own totals)
counts() {
  local n=$1 log=$2
  case $n in
    ui-test) sed -n 's/^\([0-9]*\) checks, \([0-9]*\) failed$/\1 \2/p' "$log" | tail -1 |
               awk '{ print $1 - $2, $2, 0 }';;
    lint) sed -n 's/^lint: \([0-9]*\) new (\([0-9]*\) error.*/0 \2 0/p' "$log" | tail -1;;
    *) printf '%s %s %s\n' "$(grep -c '^PASS' "$log")" "$(grep -c '^FAIL' "$log")" "$(grep -c '^SKIP' "$log")";;
  esac
}

# round <dir>: run all suites once; local and param suites in parallel, fixed ones in order
# is_local <index>: a suite that needs no server; these run first, alone, in every round, so
# wall-clock checks (ui-test's frame time) are not measured next to busy test servers
is_local() { [ "${PLAN_MODE[$1]}" = local ] && [ "${PLAN_SLOT[$1]}" = 0 ]; }

# round <dir>: run all suites once, in two phases: the local suites in parallel until they all
# finish, then the server suites. A server suite starts as soon as its slot is free, so suites on
# different slots run in parallel, suites sharing a slot (hard-coded ones, or more suites than
# slots) one after the other, in order.
round() {
  local out=$1 i n phase queue
  mkdir -p "$out"
  PIDS=()
  for phase in local server; do
    queue="" i=0
    for n in "${SUITES[@]}"; do
      if [ "$phase" = local ]; then is_local $i && queue="$queue $i"
      else is_local $i || queue="$queue $i"; fi
      i=$((i + 1))
    done
    run_queue "$out" "$queue"
  done
}

# slot_key <index>: what a suite occupies while it runs ("" for none)
slot_key() {
  local s=${PLAN_SLOT[$1]}
  if [ "$s" != 0 ]; then echo "s$s"
  elif [ "${PLAN_MODE[$1]}" = fixed ]; then echo testvm   # --as-is: all on tando-testvm
  fi
}

# drop_word <word> <list>: the list without that word (pure bash; BSD sed has no \|)
drop_word() {
  local w r=""
  for w in $2; do [ "$w" = "$1" ] || r="$r $w"; done
  printf '%s' "$r"
}

# run_queue <dir> <indexes>: start each queued suite when its server key is free and fewer than
# TANDO_ALL_SLOTS server suites run; report each as it finishes; return when the queue is empty
# and nothing from it runs
run_queue() {
  local out=$1 queue=$2 busy="" nbusy=0 left i k rc secs n running
  while :; do
    left=""
    for i in $queue; do
      k=$(slot_key "$i")
      if [ -n "$k" ]; then
        case "$busy " in *" $k "*) left="$left $i"; continue;; esac
        [ "$k" != testvm ] && [ "$nbusy" -ge "$NSLOTS" ] && { left="$left $i"; continue; }
        busy="$busy $k"; [ "$k" = testvm ] || nbusy=$((nbusy + 1))
      fi
      start "$i" "$out"
    done
    queue=$left
    running=0 i=0
    for n in "${SUITES[@]}"; do
      if [ -f "$out/$n.rc" ]; then
        if [ ! -f "$out/$n.seen" ]; then
          touch "$out/$n.seen"
          read -r rc secs < "$out/$n.rc"
          printf '  %-14s %-4s %6ss  %s\n' "$n" "$([ "$rc" = 0 ] && echo ok || echo FAIL)" "$secs" \
            "${out#"$ROOT"/}/$n.log"
          k=$(slot_key "$i")
          if [ -n "$k" ]; then busy=$(drop_word "$k" "$busy"); [ "$k" = testvm ] || nbusy=$((nbusy - 1)); fi
        fi
      elif [ -n "${PIDS[$i]:-}" ]; then
        running=$((running + 1))
      fi
      i=$((i + 1))
    done
    [ "$running" = 0 ] && [ -z "$queue" ] && return 0
    sleep 1
  done
}

if [ -z "$report" ]; then
  i=0
  echo "test/all.sh: ${#SUITES[@]} suites, $repeat round(s); logs in ${RUN#"$ROOT"/}"
  for n in "${SUITES[@]}"; do printf '  %-14s %s\n' "$n" "$(how $i)"; i=$((i + 1)); done
  claim_servers || exit 2
  r=1
  while [ "$r" -le "$repeat" ]; do
    if [ "$repeat" = 1 ]; then OUT=$RUN; else OUT=$RUN/round-$r; echo "round $r/$repeat"; fi
    round "$OUT"
    r=$((r + 1))
  done
  awk -v a="$T0" -v b="$(clock)" 'BEGIN { printf "%d\n", b - a }' > "$RUN/elapsed"
fi

# ---- summary ----------------------------------------------------------------------------------

ui_init
fails=0
rows="SUITE	RESULT	PASSED	FAILED	SKIPPED	TIME	LOG"
for n in "${SUITES[@]}"; do
  okr=0 tot=0 sp=0 sf=0 sk=0 st=0 allskip=0
  r=1
  while [ "$r" -le "$repeat" ]; do
    if [ "$repeat" = 1 ]; then d=$RUN; else d=$RUN/round-$r; fi
    rc=1 secs=0 p=0 f=0 k=0
    [ -f "$d/$n.rc" ] && read -r rc secs < "$d/$n.rc"
    [ -f "$d/$n.log" ] && read -r p f k < <(counts "$n" "$d/$n.log")
    # a round where every check was skipped proves nothing: it fails unless skips are allowed
    if [ "${p:-0}" = 0 ] && [ "${f:-0}" = 0 ] && [ "${k:-0}" -gt 0 ]; then
      allskip=$((allskip + 1)); [ "$allow_skip" = 1 ] || rc=skipped
    fi
    [ "$rc" = 0 ] && okr=$((okr + 1))
    sp=$((sp + ${p:-0})) sf=$((sf + ${f:-0})) sk=$((sk + ${k:-0}))
    st=$(awk -v a="$st" -v b="$secs" 'BEGIN { print a + b }')
    tot=$((tot + 1)) r=$((r + 1))
  done
  if [ "$okr" = "$tot" ]; then ui_badge_v ok "pass"
  elif [ "$allskip" -gt 0 ] && [ "$allow_skip" = 0 ]; then ui_badge_v failed "skipped"; fails=$((fails + 1))
  else ui_badge_v failed "fail"; fails=$((fails + 1)); fi
  res=$UI_RET
  [ "$repeat" -gt 1 ] && res="$res $okr/$tot"
  ui_dur_v "${st%.*}"
  rows="$rows
$n	$res	$sp	$sf	$sk	$UI_RET	${d#"$ROOT"/}/$n.log"
done
total=$(cat "$RUN/elapsed" 2> /dev/null || echo 0)
ui_box_open "test/all.sh" "$(date '+%Y-%m-%d %H:%M')"
ui_table "l,l,r,r,r,r,l!1" <<< "$rows"
ui_box_close "$([ "$fails" = 0 ] && echo "all passed" || echo "$fails suite(s) failed")  total $(ui_dur "$total")"

# ---- flaky checks -----------------------------------------------------------------------------

if [ "$repeat" -gt 1 ]; then
  echo
  echo "Checks that did not pass in every round:"
  for n in "${SUITES[@]}"; do
    for d in "$RUN"/round-*; do
      # key: the check text up to the first ":" or "(", digits after the id replaced by #
      perl -ne 'next unless /^(PASS|FAIL):? (.*)$/; my ($r, $t) = ($1, $2);
        my ($id, $rest) = $t =~ /^(\S+)\s*(.*)$/; $rest //= ""; $rest =~ s/\s*[:(].*//; $rest =~ s/[0-9.]+/#/g;
        print "$r\t$id $rest\n"' "$d/$n.log" | sed "s|\$|	${d#"$ROOT"/}/$n.log|"
    done > "$RUN/$n.checks"
    rounds=$repeat
    awk -F'\t' -v rounds="$rounds" -v suite="$n" '
      { k = $2; if ($1 == "FAIL") { f[k]++; logs[k] = logs[k] " " $3 } else p[k]++ ; seen[k] = 1 }
      END { for (k in seen) if (f[k] > 0) {
              kind = (f[k] >= rounds && p[k] == 0) ? "always fails" : "flaky"
              printf "  %-12s %-40s failed %d/%d (%s)%s\n", suite, k, f[k], rounds, kind, logs[k] } }' \
      "$RUN/$n.checks"
  done | sort | grep . || echo "  none"
fi
[ "$fails" = 0 ]
