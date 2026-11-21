#!/bin/bash
# test/e2e-jobs.sh: scheduled jobs (job.<name> in tando.conf) on a test server.
#   J1  cron and systemd schedules are checked before anything is built or sent
#   J2  the cron translation means what cron means: 40 schedules, the next times systemd computes
#       from the translation against test/cron-ref.py (the cron rules, independent of the translator)
#   J3  tando jobs: next runs, zone, result words, duration; jobs log: each run's own output
#   J4  the history: bounded, no output in it; failing jobs show in ls and status
#   J5  spread and missed run: what the timer says
#   J6  a job follows its release: code, env, a failed deploy, rollback, removal
#   J7  a run still going on is not started twice, nor at once when it ends (a real timer fires here)
#   J8  pause and resume: across a deploy and a restart of the host, no run made up on resume
# Usage: test/e2e-jobs.sh   (server: TANDO_TEST_NAME, TANDO_TEST_SSH_PORT, TANDO_TEST_HTTP_PORT)
# bash 3.2 compatible. Takes about 4 minutes.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-jobs
srv() { "$SSH" "$@" < /dev/null; }
t_server_up --reset || exit 1
t_host_add test
"$R" host setup test public_port="$T_HTTP_PORT" > "$E/setup.out" 2>&1 || { tail -5 "$E/setup.out" >&2; echo "FAIL J0 host setup"; exit 1; }
AGENT=/opt/tando/bin/tando-agent
AD=/opt/tando/apps/jb
W=$E/w; mkdir -p "$W"; cp -R "$ROOT/examples/hello" "$W/jb"
cd "$W/jb" || exit 1
export TANDO_WAIT=1

# conf <extra lines...>: tando.conf of the app, with the lines given
conf() {
  { printf 'app = jb\nrecipe = node\nstart = node server.js\nhealth = /health\nmemory = 128M\nhealth_timeout = 15\n'
    for l in "$@"; do printf '%s\n' "$l"; done; } > tando.conf
}
marker() { echo "$1" > marker.txt; }
up() { "$R" up > "$E/$1.out" 2>&1; local rc=$?; cat "$E/$1.out" >&2; return $rc; }
J() { (cd "$W/jb" && COLUMNS=${COLUMNS:-120} "$R" "$@" < /dev/null); }
unit() { srv "cat /etc/systemd/system/tando-jb_job-$1.$2 2> /dev/null"; }
have() { srv "test -e /etc/systemd/system/tando-jb_job-$1.timer"; }

# ---- J1. schedules are checked before a deploy -------------------------------------------------
marker one
j1_ok() { [ "$rc" = 1 ] && [ "$rcu" = 1 ] && grep -q 'bad\|outside\|both set\|not a schedule' "$E/j1.out" &&
  ! grep -q 'staged\|building\|live in' "$E/j1u.out" && ! srv "test -e $AD"; }
for c in 'job.bad = 61 * * * * | true' 'job.bad = 0 0 1 * mon | true' 'job.bad = @reboot | true' 'job.bad = every day | true'; do
  conf "$c"
  "$R" deploy --dry-run > "$E/j1.out" 2>&1; rc=$?
  "$R" up > "$E/j1u.out" 2>&1; rcu=$?
  check "J1a refused by deploy --dry-run and by up, before a build, nothing created on the server: $c (rc=$rc/$rcu)" \
    j1_ok
done
conf 'job.bad = 0 0 1 * mon | true'; "$R" up > "$E/j1b.out" 2>&1; cat "$E/j1b.out" >&2
check "J1b a cron schedule that cannot be said in systemd: refused with the file, the line and what to write" \
  eval 'grep -q "tando.conf:7: job.bad: 0 0 1 \* mon: day-of-month and weekday are both set.*two jobs" "$E/j1b.out"'
conf 'job.bad = every day | true'; "$R" up > "$E/j1c.out" 2>&1; cat "$E/j1c.out" >&2
check "J1b2 a calendar expression systemd refuses: the server says so before the deploy, and what is accepted" \
  eval 'grep -q "bad schedule for job bad: every day (a cron schedule like" "$E/j1c.out"'

# ---- J2. the translation, against systemd and the cron rules --------------------------------------
LIST='* * * * *
*/15 * * * *
*/7 * * * *
*/59 * * * *
5 * * * *
0,15,30,45 * * * *
10-40/10 * * * *
10-50/10 * * * *
5-59/15 * * * *
0-5,10-15 * * * *
0 */2 * * *
0 */5 * * *
0 8-17 * * *
0 9-17/2 * * *
0 22,23,0 * * *
30 2 1 * *
0 0 */2 * *
0 0 */10 * *
0 0 1-7 * *
0 0 1,15 * *
0 0 31 * *
0 0 29 2 *
0 0 * jan,jul *
0 0 * */3 *
0 0 * 2,5,8,11 *
0 0 * * 0
0 0 * * 7
0 0 * * SUN
0 0 * * mon-fri
0 0 * * sat,sun
0 0 * * 0-2
0 0 * * 5-7
0 0 * * 1-3,5
0 0 * * */2
0 0 */2 * mon
15 4 * jan,jul *
@hourly
@daily
@weekly
@monthly
@yearly'
# the client's translation of each, then one ssh for all of systemd's answers
printf '%s\n' "$LIST" | while IFS= read -r e; do
  "$BASH" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; cron_to_cal "$2" && echo "$CRON_CAL"' _ "$ROOT" "$e"
done > "$E/cals.txt"
"$SSH" 'while IFS= read -r c; do echo "== $c"; systemd-analyze calendar --base-time="2026-11-20 10:07:30" --iterations=3 "$c" 2>&1; done' < "$E/cals.txt" > "$E/sysd.txt" 2>&1
n=0 bad=""
while IFS= read -r e; do
  n=$((n + 1))
  cal=$(sed -n "${n}p" "$E/cals.txt")
  want=$(python3 "$ROOT/test/cron-ref.py" "$e" "2026-11-20 10:07:30" 3)
  got=$(awk -v n="$n" '/^== / { k++; next } k == n' "$E/sysd.txt" |
    sed -En 's/^ *(Next elapse|Iteration #[0-9]*): [A-Za-z]* ([0-9-]+ [0-9:]+) UTC$/\2/p')
  [ -n "$cal" ] && [ "$got" = "$want" ] || bad="$bad [$e -> $cal: systemd $(echo $got | cut -c1-60), cron $(echo $want | cut -c1-60)]"
done <<EOF
$LIST
EOF
ok2=0; [ -z "$bad" ] && [ "$n" -ge 40 ] && ok2=1
[ "$ok2" = 1 ] || echo "J2 differences:$bad" >&2
check "J2 $n cron schedules: the translation runs at the times cron would (systemd-analyze vs test/cron-ref.py)" t_eq "$ok2" 1

# ---- v1: the jobs of the next checks ---------------------------------------------------------------
# a counts its runs and prints run-N (and extra-2 in its second); z prints nothing; f fails with 3; flip fails
# until the suite creates ok; slow outlives its timeout; hog outgrows the memory limit; show names its release
conf 'job.a = yearly | n=$(cat $TANDO_DATA_DIR/n 2>/dev/null || echo 0); n=$((n + 1)); echo $n > $TANDO_DATA_DIR/n; echo run-$n; [ $n = 2 ] && echo extra-$n; true' \
  'job.z = yearly | true' 'job.f = yearly | echo failing >&2; exit 3' \
  'job.flip = yearly | test -e $TANDO_DATA_DIR/ok' \
  'job.slow = yearly | sleep 30' 'job.slow.timeout = 2' \
  'job.hog = yearly | node -e "a=[];for(;;)a.push(Buffer.alloc(40e6,1))"' \
  'job.hist = yearly | true' \
  'job.q = */15 * * * * | true' 'job.qs = 0 9 * * mon-fri | true' 'job.qs.missed = skip' \
  'job.show = yearly | echo old-$(cat marker.txt)-${JOBENV:-none}'
marker one
up v1; rc=$?
check "J3a deploy v1 with cron and calendar jobs (rc=$rc)" t_eq "$rc" 0
check "J1c a job deployed from a cron schedule: its timer has the OnCalendar text, and tando jobs shows what was written" \
  eval 'unit q timer | grep -qx "OnCalendar=\*-\*-\* \*:00/15:00" && J jobs > "$E/jobs0.out" 2>&1 && grep -q "^│ q  *\*/15 \* \* \* \*" "$E/jobs0.out" &&
        grep -q "^│ qs  *0 9 \* \* mon-fri" "$E/jobs0.out" && unit qs timer | grep -qx "OnCalendar=Mon..Fri \*-\*-\* 09:00:00"'
cat "$E/jobs0.out" >&2
# (a later run shows its date when it falls on another day: near midnight the second or third does)
check "J3b tando jobs before any run: never, the next three runs by the server's clock and its zone" \
  eval 'grep -q "next runs, server time (" "$E/jobs0.out" && grep -Eq "^│   q  [0-9-]+ [0-9:]+, ([0-9-]+ )?[0-9:]+, ([0-9-]+ )?[0-9:]+" "$E/jobs0.out" &&
        grep -q "^│ a  *yearly  *in\|^│ a  *yearly  *\([0-9]\{4\}-\)\?[0-9][0-9]-" "$E/jobs0.out" && grep -q "^│ a .* never " "$E/jobs0.out"'
check "J3c the server's zone is named (the time zone of every schedule)" grep -Eq 'server time \((UTC|[A-Z]{3,4})' "$E/jobs0.out"
check "J3c2 one word for the zone: GMT in the header as in the NEXT column, never UTC beside it" \
  eval 'grep -q "server time (GMT)" "$E/jobs0.out" && ! grep -q UTC "$E/jobs0.out"'
ny=$(($(date -u +%Y) + 1))
check "J3b2 a next run in another year shows its year (a yearly job: $ny-01-01), in the table and in the next runs" \
  eval 'grep -q "^│ a  *yearly  *$ny-01-01 00:00 GMT" "$E/jobs0.out" && grep -q "^│   a  $ny-01-01 00:00, $((ny + 1))-01-01 00:00" "$E/jobs0.out"'

# runs: a three times, z twice, f, flip, slow, hog
for i in 1 2 3; do J jobs run a > "$E/run-a$i.out" 2>&1; done
J jobs run z > /dev/null 2>&1; J jobs run z > /dev/null 2>&1
J jobs run f > "$E/run-f.out" 2>&1; rcf=$?
J jobs run slow > "$E/run-slow.out" 2>&1; rcs=$?
J jobs run hog > "$E/run-hog.out" 2>&1
J jobs > "$E/jobs1.out" 2>&1; cat "$E/jobs1.out" >&2
check "J3d the result of each kind of end, in words: ok, exit 3 (rc=$rcf), timed out (rc=$rcs), killed (memory)" \
  eval 'grep "^│ a " "$E/jobs1.out" | grep -q "● ok" && grep "^│ f " "$E/jobs1.out" | grep -q "✗ exit 3" &&
        grep "^│ slow " "$E/jobs1.out" | grep -q "✗ timed out" && grep "^│ hog " "$E/jobs1.out" | grep -q "✗ killed (memory)" &&
        [ $rcf = 3 ] && [ $rcs = 124 ]'
check "J3e how long the last run took is shown (slow: about its 2 s limit)" \
  eval 'grep "^│ slow " "$E/jobs1.out" | grep -Eq " 2\.[0-9]s " && grep "^│ a " "$E/jobs1.out" | grep -Eq " 0\.[0-9]s "'
check "J3f the last run time is the run's, not the timer's (a: just now, though its timer never fired)" \
  eval 'grep "^│ a " "$E/jobs1.out" | grep -q "just now\|s ago"'
J jobs log a -n 3 > "$E/log-a.out" 2>&1; cat "$E/log-a.out" >&2
check "J3g jobs log a: three runs, each with its own output, oldest first" \
  eval 'l1=$(grep -n "^  run-1$" "$E/log-a.out" | cut -d: -f1); l2=$(grep -n "^  run-2$" "$E/log-a.out" | cut -d: -f1);
        lx=$(grep -n "^  extra-2$" "$E/log-a.out" | cut -d: -f1); l3=$(grep -n "^  run-3$" "$E/log-a.out" | cut -d: -f1);
        [ -n "$l1" ] && [ "$l1" -lt "$l2" ] && [ "$l2" -lt "$lx" ] && [ "$lx" -lt "$l3" ] && [ "$(grep -c "● ok" "$E/log-a.out")" = 3 ] &&
        [ "$(grep -c "^  " "$E/log-a.out")" = 4 ]'
J jobs log a -n 1 > "$E/log-a1.out" 2>&1
check "J3h jobs log a -n 1: the last run only, none of the earlier ones' lines" \
  eval 'grep -q "^  run-3$" "$E/log-a1.out" && ! grep -q "run-[12]\|extra" "$E/log-a1.out"'
J jobs log z -n 2 > "$E/log-z.out" 2>&1
check "J3i a job that prints nothing: its runs are listed with no lines (the lines of a neighbour run are not borrowed)" \
  eval '[ "$(grep -c "● ok" "$E/log-z.out")" = 2 ] && ! grep -q "^  " "$E/log-z.out"'
J jobs log f > "$E/log-f.out" 2>&1
check "J3j a failed run's log: its result and its stderr" eval 'grep -q "✗ exit 3" "$E/log-f.out" && grep -q "^  failing$" "$E/log-f.out"'
J jobs log show > "$E/log-never.out" 2>&1; rc=$?
check "J3k a job that never ran says so (rc=$rc)" eval '[ $rc = 0 ] && grep -q "has not run yet" "$E/log-never.out"'
J jobs log nosuch > /dev/null 2>&1; rc=$?
check "J3l jobs log of a job that does not exist fails (rc=$rc)" eval '[ $rc != 0 ]'

# ---- J4. the history ---------------------------------------------------------------------------------
check "J4a the history of a job: one line per run, a bit of text each, no job output in it" \
  eval '[ "$(srv "sudo cat $AD/jobhist/a | wc -l")" = 3 ] && ! srv "sudo grep -rl run-1 $AD/jobhist"'
# (seeded: 70 lines, the first ten failed runs; three more through the hook, as the unit's ExecStopPost calls it)
srv "for i in \$(seq 1 70); do if [ \$i -le 10 ]; then printf '1\\t1.0\\texit-code\\t1\\t\\n'; else printf '1\\t1.0\\tsuccess\\t0\\t\\n'; fi; done | sudo tee $AD/jobhist/hist > /dev/null
  for i in 1 2 3; do sudo env SERVICE_RESULT=success EXIT_STATUS=0 $AGENT job-end jb hist; done"
lines=$(srv "sudo cat $AD/jobhist/hist | wc -l")
check "J4b the history keeps the last 50 runs, never more than 70 (73 runs: $lines lines, the first ten gone)" \
  eval '[ "$lines" -ge 50 ] && [ "$lines" -le 70 ] && ! srv "sudo grep -q exit-code $AD/jobhist/hist"'
check "J4c the last line of the history is the last run (tando jobs: ok)" \
  eval 'J jobs 2>&1 | grep "^│ hist " | grep -q "● ok"'
# a failing job is alerted, shown in ls and in status, and clears with its next success
J jobs run flip > /dev/null 2>&1; srv 'sudo systemctl start tando-watch.service'
J status > "$E/status-fail.out" 2>&1; "$R" ls > "$E/ls-fail.out" 2>&1
check "J4d a failed run: tando status shows the alert job.flip, tando ls counts it" \
  eval 'grep -q "job.flip" "$E/status-fail.out" && grep -q "alert" "$E/ls-fail.out"'
J jobs run flip > /dev/null 2>&1; srv 'sudo systemctl start tando-watch.service'
check "J4e a second failed run while it fires is still one alert" \
  eval '[ "$(J status 2>&1 | grep -c "alert.*job.flip")" -le 1 ] && J status 2>&1 | grep -q "job.flip"'
srv "sudo -u tando-jb touch $AD/shared/data/ok"; J jobs run flip > /dev/null 2>&1; srv 'sudo systemctl start tando-watch.service'
check "J4f the next success resolves it" eval '! J status 2>&1 | grep -q "job.flip"'

# ---- J5. spread and missed run ---------------------------------------------------------------------------
check "J5a the defaults: starts spread over 15 s, a missed run made up once (Persistent=true)" \
  eval 'unit q timer | grep -qx "RandomizedDelaySec=15" && unit q timer | grep -qx "Persistent=true" &&
        [ "$(srv "systemctl show -P RandomizedDelayUSec tando-jb_job-q.timer")" = 15s ]'
check "J5b job.<name>.missed = skip: Persistent=false for that job only" \
  eval 'unit qs timer | grep -qx "Persistent=false" && unit q timer | grep -qx "Persistent=true"'

# ---- J6. a job follows its release ------------------------------------------------------------------------
check "J6a v1: the job runs v1's code (old-one)" eval 'J jobs run show 2>&1 | grep -q "^old-one-none"'
J env set JOBENV=x1 > /dev/null 2>&1
check "J6b an env change reaches the next run of a job without a deploy" eval 'J jobs run show 2>&1 | grep -q "^old-one-x1"'
marker two
conf 'job.show = yearly | echo new-$(cat marker.txt)-${JOBENV:-none}' 'job.only2 = yearly | true' \
  'job.long = *:*:0/4 | d=$TANDO_DATA_DIR; if [ -e $d/busy ]; then echo overlap >> $d/bad; fi; touch $d/busy; echo s >> $d/starts; sleep 7; rm -f $d/busy' \
  'job.pz = *:*:0/10 | echo pz' 'job_spread = 0' 'job.hist = yearly | true'
up v2; rc=$?
check "J6c deploy v2 (rc=$rc): the job runs v2's code and the same env (new-two-x1)" eval 'J jobs run show 2>&1 | grep -q "^new-two-x1"'
check "J6d v2's new job has its timer; v1's other jobs are gone with the release that had them" \
  eval 'have only2 && ! have flip && ! have f && ! have a'
check "J5c job_spread = 0 for all: no RandomizedDelaySec in the timers" \
  eval '! unit only2 timer | grep -q RandomizedDelaySec && ! unit show timer | grep -q RandomizedDelaySec'
# a deploy that fails: the old jobs stay, the new ones never appear
marker three
conf 'job.show = yearly | echo three-$(cat marker.txt)' 'job.only3 = yearly | true' 'job.only2 = yearly | true' 'job_spread = 0'
sed -i.bak 's|^start = .*|start = node nothere.js|' tando.conf; rm -f tando.conf.bak
up v3; rc=$?
check "J6e a deploy that fails (rc=$rc) leaves the live release's jobs: show still prints new-two-x1, only3 has no timer" \
  eval '[ $rc != 0 ] && J jobs run show 2>&1 | grep -q "^new-two-x1" && ! have only3 && have only2 &&
        ! unit show service | grep -q three'
J rollback > "$E/rollback.out" 2>&1; rc=$?; cat "$E/rollback.out" >&2
check "J6f rollback to v1 (rc=$rc): the older release's jobs and code are back (old-one-x1), v2's job is gone" \
  eval '[ $rc = 0 ] && J jobs run show 2>&1 | grep -q "^old-one-x1" && have flip && have a && ! have only2 && ! have long'

# ---- J7. a job still running is not started twice; a real timer fires ---------------------------------------
marker two
# (long has no history yet: v2's runs of a job of that name are not this one's. A run of v2's that
# was still going on at the rollback finishes first, and writes its line)
t_until 15 eval '! srv "test -e /etc/systemd/system/tando-jb_job-long.service"'
srv "sudo rm -f $AD/jobhist/long $AD/jobhist/long.*"
conf 'job.show = yearly | echo new-$(cat marker.txt)-${JOBENV:-none}' \
  'job.long = *:*:0/4 | d=$TANDO_DATA_DIR; if [ -e $d/busy4 ]; then echo overlap >> $d/bad4; fi; touch $d/busy4; date +%s.%N >> $d/starts4; sleep 5; date +%s.%N >> $d/ends4; rm -f $d/busy4' \
  'job.pz = *:*:0/10 | echo pz' 'job.rm = yearly | sleep 45; echo done >> $TANDO_DATA_DIR/rmdone' 'job_spread = 0'
up v4; rc=$?
check "J7a deploy v4 with a job every 4 s that takes 5 s (rc=$rc)" t_eq "$rc" 0
t_until 20 srv "sudo test -s $AD/shared/data/starts4"
t0=$SECONDS
J jobs > "$E/jobs7.out" 2>&1; cat "$E/jobs7.out" >&2
check "J7b the timer started it by itself (no run by hand): a run is going on and tando jobs says running" \
  eval 'grep "^│ long " "$E/jobs7.out" | grep -q "running"'
check "J7b2 before its first run has ended: LAST never, RESULT running (not ok)" \
  eval 'grep "^│ long " "$E/jobs7.out" | grep -q " never  *● running" && ! grep "^│ long " "$E/jobs7.out" | grep -q "● ok"'
sleep 22   # (a wait that proves something did not happen: no second copy over the next five timer times)
starts4=$(srv "sudo cat $AD/shared/data/starts4 | wc -l")
# the shortest time from the end of a run to the start of the next: a time of the timer that passed
# during a run is skipped, so the next run waits for the next time (about 3 s here), never 0 s
gap=$(srv "sudo cat $AD/shared/data/starts4; echo; sudo cat $AD/shared/data/ends4" |
  awk 'NF == 0 { e = 1; next } !e { s[n++] = $1; next } { f[m++] = $1 }
       END { g = 99; for (i = 0; i + 1 < n && i < m; i++) if (s[i + 1] - f[i] < g) g = s[i + 1] - f[i]; printf "%.1f", g }')
# (t0 is taken once the first start was seen, up to a few seconds after it: those count too)
span=$((SECONDS - t0)); most=$(((span + 4) / 8 + 1))
check "J7c in $span s the timer fired every 4 s, the job takes 5 s: it started $starts4 times (at most $most, at its times, 2 at least), never two at once, never at once after a run (at least ${gap} s between)" \
  eval '[ "$starts4" -ge 2 ] && [ "$starts4" -le "$most" ] && ! srv "sudo test -e $AD/shared/data/bad4" && awk -v g="$gap" "BEGIN { exit !(g >= 1) }"'
check "J7d the runs are in the history with their duration (5 s)" \
  eval 'J jobs 2>&1 | grep "^│ long " | grep -Eq "● ok +[0-9]+ ?s|5\.[0-9]s"'

# ---- J8. pause and resume ----------------------------------------------------------------------------------------
J jobs pause pz > "$E/pause.out" 2>&1; rc=$?
check "J8a pause: the timer is stopped and disabled, the list says paused (rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$(srv "systemctl is-enabled tando-jb_job-pz.timer; systemctl is-active tando-jb_job-pz.timer" | tr "\n" " ")" = "disabled inactive " ] &&
        J jobs 2>&1 | grep "^│ pz " | grep -q "paused"'
echo '# a change' >> tando.conf; up v5; rc=$?
check "J8b a deploy keeps it paused (rc=$rc), the other jobs' timers run" \
  eval '[ "$(srv "systemctl is-enabled tando-jb_job-pz.timer" 2>&1)" = disabled ] && srv "systemctl -q is-active tando-jb_job-long.timer" &&
        J jobs 2>&1 | grep "^│ pz " | grep -q "paused"'
J jobs run pz > "$E/pz-run.out" 2>&1; rc=$?
check "J8c a run by hand of a paused job works (rc=$rc)" eval '[ $rc = 0 ] && grep -q "^pz$" "$E/pz-run.out"'
runs0=$(srv "sudo cat $AD/jobhist/pz | wc -l")
sleep 12   # (a paused job's time goes by)
J jobs resume pz > /dev/null 2>&1
sleep 3
runs1=$(srv "sudo cat $AD/jobhist/pz | wc -l")
# a run made up for the time it was off would start at the resume, off the schedule; a run in
# these 3 s at one of its times (every 10 s: :x0, plus at most 1 s of systemd's accuracy) is due.
# (Counting runs instead failed whenever a time of the schedule fell in the 3 s: 1 run in 3.)
offsched=$(srv "sudo tail -n +$((runs0 + 1)) $AD/jobhist/pz" | awk -F'\t' '$1 % 10 > 1 { print $1 }')
check "J8d resume: the timer is back, and the 12 s it was off were not made up (runs since: $((runs1 - runs0)), off the schedule: ${offsched:-none})" \
  eval '[ "$(srv "systemctl is-enabled tando-jb_job-pz.timer; systemctl is-active tando-jb_job-pz.timer" | tr "\n" " ")" = "enabled active " ] && [ -z "$offsched" ]'
t_until 30 eval '[ "$(srv "sudo cat $AD/jobhist/pz | wc -l")" -gt "$runs0" ]'
check "J8e and it runs at its next time again" eval '[ "$(srv "sudo cat $AD/jobhist/pz | wc -l")" -gt "$runs0" ]'
J jobs pause nosuch > "$E/pause-no.out" 2>&1; rc=$?
check "J8f pausing a job that does not exist fails and says so (rc=$rc)" eval '[ $rc != 0 ] && grep -q "has no job nosuch" "$E/pause-no.out"'
J jobs pause pz > /dev/null 2>&1
if [ "${TANDO_TEST_OWNED:-0}" = 1 ]; then
  docker restart "$T_NAME" > /dev/null
  t_until 90 srv true
  t_until 60 eval '[ "$(srv "systemctl is-active tando-jb_job-long.timer" 2>&1)" = active ]'
  check "J8g after the host restarted: the paused job is still off, the others' timers are on" \
    eval '[ "$(srv "systemctl is-enabled tando-jb_job-pz.timer" 2>&1)" = disabled ] && ! srv "systemctl -q is-active tando-jb_job-pz.timer" &&
          J jobs 2>&1 | grep "^│ pz " | grep -q paused'
else skip "J8g host restart: $T_NAME is not ours to restart"; fi
# removal: a job taken out of tando.conf loses its timer and its pause; a run of it going on finishes
srv "sudo systemctl start --no-block tando-jb_job-rm.service"
t_until 10 eval '[ "$(srv "systemctl show -P ActiveState tando-jb_job-rm.service")" = activating ]'
conf 'job.show = yearly | true'
up v6
# (the job units follow the release once it is verified, after its short soak)
t_until 20 eval '! have rm'
rmst=$(srv "systemctl show -P ActiveState tando-jb_job-rm.service; ls /etc/systemd/system | grep -c tando-jb_job-rm.timer" | tr '\n' ' ')
check "J6h a job removed while a run of it goes on: its timer goes with the release, the run goes on (state, timers: $rmst)" \
  eval '[ "$rmst" = "activating 0 " ]'
t_until 90 eval 'srv "sudo test -e $AD/shared/data/rmdone && ! test -e /etc/systemd/system/tando-jb_job-rm.service"'
t_until 20 eval '[ -z "$(srv "systemctl list-units --all --no-legend tando-jb_job-rm.service")" ]'
check "J6i that run finished (not killed) and is in the history (ok); then its unit went: no file, not listed, not failed" \
  eval 'srv "sudo test -e $AD/shared/data/rmdone" && srv "sudo tail -1 $AD/jobhist/rm" | grep -q "	success	" &&
        ! srv "test -e /etc/systemd/system/tando-jb_job-rm.service" &&
        [ -z "$(srv "systemctl list-units --all --no-legend tando-jb_job-rm.service; systemctl --failed --no-legend | grep tando-jb_job")" ]'
# (a run of long going on at the deploy keeps its unit file until it ends: at most 5 s)
t_until 15 eval '! srv "ls /etc/systemd/system/ | grep -q tando-jb_job-long"'
check "J6g jobs removed from tando.conf: their units and timers are gone, the pause with them" \
  eval '! have long && ! have pz && ! srv "ls /etc/systemd/system/ | grep -q tando-jb_job-long" && ! srv "sudo test -e $AD/jobpaused" &&
        [ "$(J jobs 2>&1 | grep -c "^│ \\(long\\|pz\\) ")" = 0 ] && J jobs 2>&1 | grep -q "^│ show "'
t_done
