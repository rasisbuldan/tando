#!/bin/bash
# test/portability-client.sh: the Linux client flow of test/portability.sh. Runs as root inside a
# throwaway container made from the test server image, with the repository at /tando (read-only).
# Environment: PART (linux | busybox), APP (app name to deploy), IP (the test server's address).
# Prints PASS/FAIL lines and "INCOMPAT <part> <file>:<line> <error>" for every tool error.
# lint: side=linux
# lint: file-allow RL06 a throwaway container: nobody else can own /tmp names
set -u
R=/tando/bin/tando
P=L
export TANDO_CONFIG_DIR=/tmp/cfg TANDO_COLOR=never COLUMNS=100 LC_ALL=C.UTF-8

if [ "$PART" = busybox ]; then
  # BusyBox applets in front of the GNU tools, perl gone: what an Alpine laptop or runner has.
  P=B
  cp /bb/ld-musl-* /lib/
  mkdir -p /bbbin
  for a in $(/bb/busybox --list); do
    case $a in sh|ash|bash|ssh|scp|rsync|curl) continue;; esac
    ln -s /bb/busybox "/bbbin/$a"
  done
  export PATH=/bbbin:$PATH
  rm -f /usr/bin/perl /usr/bin/perl5*
fi
# lint: allow RL04 ssh -V runs locally
echo "client $PART: bash $BASH_VERSION, $(rsync --version | head -1), $(ssh -V 2>&1)," \
  "sed is $(sed --version 2>&1 | head -1)" >&2

cp /tando/test/server/id_test /tmp/key && chmod 600 /tmp/key

# run <label> <args...>: tando under xtrace (fd 9 shares stderr, so trace and errors stay in order);
# every error-looking line is reported with the tando file:line traced just before it
run() {
  local label=$1 rc
  shift
  (cd "${CWD:-/tmp}" && env BASH_XTRACEFD=9 PS4='+${BASH_SOURCE[0]#/tando/}:${LINENO}: ' \
    bash -x "$R" "$@") > /tmp/out 2> /tmp/both 9>&2
  rc=$?
  awk -v part="$PART" -v label="$label" '
    /^\++[^ ]*:[0-9]+: / { where = $1; sub(/^\++/, "", where); sub(/:$/, "", where); next }
    /illegal option|invalid option|unrecognized option|unknown option|not found|syntax error/ ||
    /bad substitution|unbound variable|Can.t locate|applet not found|integer expression expected/ ||
    /bad number|invalid number|^usage: |^Usage: |BusyBox v/ {
      print "INCOMPAT " part " " where " (" label "): " $0 }' /tmp/both
  cat /tmp/out
  return $rc
}

ok() { echo "PASS $P$*"; }
no() { echo "FAIL $P$*"; tail -5 /tmp/both | grep -v '^+' | sed 's/^/    /'; }
step() { local n=$1; shift; if "$@" > /dev/null; then ok "$n"; else no "$n"; fi; }
get() { curl -s -m 5 -H "Host: $APP.localhost" "http://$IP${1:-/}"; }

step "1 host add (host key trusted with --yes)" run "host add" host add t "vmadmin@$IP" --port 22 --key /tmp/key --yes
step "2 host setup" run "host setup" host setup t

mkdir -p "/tmp/w/$APP"
cp -R /tando/examples/hello/. "/tmp/w/$APP/"
grep -v '^app *=' "/tmp/w/$APP/tando.conf" > /tmp/conf &&
  { echo "app = $APP"; cat /tmp/conf; } > "/tmp/w/$APP/tando.conf"
echo 1 > "/tmp/w/$APP/VERSION"
CWD=/tmp/w/$APP

step "3 up (create + first deploy)" run up up
v=$(get / | sed -n 's/^hello v\([0-9]*\).*/\1/p')
if [ "$v" = 1 ]; then ok "4 link answers version 1"; else no "4 link answers version 1 (got [$v])"; fi
echo 2 > "/tmp/w/$APP/VERSION"
if run deploy deploy > /tmp/d2; then ok "5 deploy"; else no "5 deploy"; fi
v=$(get / | sed -n 's/^hello v\([0-9]*\).*/\1/p')
if [ "$v" = 2 ]; then ok "6 link answers version 2"; else no "6 link answers version 2 (got [$v])"; fi
if grep -qE '[0-9]+ files? changed' /tmp/d2; then ok "7 deploy box shows the upload"; else no "7 deploy box shows the upload"; fi

n=8
for c in "host ls" "ls" "ls --all" "status" "history" "releases" "env ls" "logs -n 5" "jobs" "doctor"; do
  # shellcheck disable=SC2086 # the command words are split on purpose
  step "$n $c" run "$c" $c
  n=$((n + 1))
done
# plugin commands that only read (when present): they format server timestamps with date
for c in "audit" "requests --last 1h" "requests errors"; do
  [ -f "/tando/lib/cmd-${c%% *}.sh" ] || continue
  # shellcheck disable=SC2086 # the command words are split on purpose
  if run "$c" $c > /dev/null; then ok "$n $c"
  elif grep -q 'unknown verb' /tmp/both; then echo "SKIP $P$n $c (the agent has no verb for it yet)"
  else no "$n $c"; fi
  n=$((n + 1))
done
step "$n env set (value with spaces)" run "env set" env set "GREETING=hi there"
n=$((n + 1))
g=$(get / | sed -n 's/.*greeting=//p')
if [ "$g" = "hi there" ]; then ok "$n env value reaches the app"; else no "$n env value reaches the app (got [$g])"; fi
n=$((n + 1))
if command -v perl > /dev/null 2>&1; then
  run "ls width" ls > /tmp/ls
  w=$(perl -CSD -ne 'chomp; s/\e\[[0-9;?]*[A-Za-z]//g; $m = length if length > $m; END { print $m + 0 }' /tmp/ls)
  if [ "$w" -le 100 ]; then ok "$n ls fits 100 columns (widest $w)"; else no "$n ls fits 100 columns (widest $w)"; fi
fi
exit 0
