# shellcheck shell=bash disable=SC2034 # variables are read inside the eval'd check strings
# test/sec2/lease-jobs.sh: sourced by test/e2e-sec2.sh after sec3.sh (alpha, the compromised app,
# and bravo, both with deploy keys). bash 3.2.
#   L: the upload lease finds an upload by its receiver (executable, owner, working directory),
#      never by a command line another process chooses (pgrep -f / pkill -f before)
#   J: job units are tando-<app>_job-<name>: apps alpha and alpha-job (and alpha-job-tick, whose
#      service had the name of alpha's job tick) never touch each other's jobs; the units of the
#      form before are renamed by host setup, each app's own only

AG=/opt/tando/bin/tando-agent
BI=/opt/tando/apps/bravo/incoming
alive() { rootsh "kill -0 $1 2> /dev/null"; }
# a stale upload lease of bravo: 2 minutes old, its client gone, nothing written into incoming/
stale_lease() {
  rootsh "printf 'token=00000000-0000-4000-8000-000000000000\nwho=gone@laptop\nstarted=%s\nstarted_ds=0\n' \$((\$(date +%s) - 120)) > /opt/tando/apps/bravo/upload &&
    find $BI -exec touch -h -d '5 minutes ago' {} +"
}
bravo_v() { echo "$1" > "$W/w/bravo/VERSION"; }

# L1: a process of alpha with bravo's incoming/ in its command line does not stop bravo's deploys
dpid=$(x "nohup bash -c 'while :; do sleep 1; done' $BI > /dev/null 2>&1 < /dev/null & echo \$!" | tr -dc 0-9)
check "L1a alpha runs a decoy with $BI in its command line (pid ${dpid:-none})" \
  eval '[ -n "$dpid" ] && rootsh "tr \"\\0\" \" \" < /proc/$dpid/cmdline | grep -q apps/bravo/incoming && test \$(stat -c %U /proc/$dpid) = tando-alpha"'
v0=$(cat "$W/w/bravo/VERSION"); bravo_v l1
(cd "$W/w/bravo" && "$R" up > "$E/l1-up.out" 2>&1); rc=$?
check "L1b bravo deploys (rc=$rc): alpha's decoy is no upload of bravo" \
  eval '[ $rc = 0 ] && ! grep -q "another upload" "$E/l1-up.out" && get bravo | grep -q l1'
[ $rc = 0 ] || tail -5 "$E/l1-up.out" >&2
check "L1c alpha's decoy was not killed" alive "$dpid"

# L2: taking over a stale lease kills no process that only names incoming/ in its arguments: not
# the admin's (a shell, an editor, a grep), not another app's
apid=$(srv "nohup bash -c 'while :; do sleep 1; done' $BI > /dev/null 2>&1 < /dev/null & echo \$!" | tr -dc 0-9)
stale_lease
tok=$(rootsh "$AG begin bravo other@laptop" 2> "$E/l2-begin.err" | sed -n 's/^token=//p')
check "L2a a stale lease of bravo is taken over (token ${tok:-none}; $(tr '\n' ' ' < "$E/l2-begin.err"))" test -n "$tok"
check "L2b the admin's process with $BI in its arguments survives the takeover" alive "$apid"
check "L2c and so does alpha's" alive "$dpid"
[ -n "$tok" ] && echo "$tok" | rootsh "$AG end bravo" > /dev/null

# L3: the receiver a takeover must end is found: an rsync server as incoming/'s owner, working in
# incoming/, whose client is gone (it waits for input for ever: a dropped connection). incoming/
# as an app without a deploy key has it, the admin's (begin ends every process of a deploy user
# anyway, so bravo's own layout would prove nothing); given back to bravo's deploy user after L4
# lint: allow RL02 runs on the Linux test server
ow0=$(rootsh "stat -c %U $BI") ow=vmadmin
rootsh "chown $ow $BI"
rootsh "runuser -u $ow -- bash -c 'cd $BI && sleep 600 | exec rsync --server -logDtprze.iLsfxCIvu --delete . . ' > /dev/null 2>&1 < /dev/null &"
rx() { rootsh "pgrep -u $ow -x rsync" | head -1; }
T_UNTIL_STEP=0.5 t_until 10 eval '[ -n "$(rx)" ]'; rpid=$(rx)
check "L3a a hung rsync receiver of $ow runs in bravo's incoming/ (pid ${rpid:-none})" test -n "$rpid"
stale_lease
tok=$(rootsh "$AG begin bravo other@laptop" 2> "$E/l3-begin.err" | sed -n 's/^token=//p')
check "L3b the stale lease is taken over (token ${tok:-none}; $(tr '\n' ' ' < "$E/l3-begin.err"))" test -n "$tok"
check "L3c and its receiver was ended first" eval '[ -n "$rpid" ] && ! alive "$rpid"'
[ -n "$tok" ] && echo "$tok" | rootsh "$AG end bravo" > /dev/null
rootsh "pkill -u $ow -x sleep" 2> /dev/null
# L4: the same before the receiver has changed into incoming/ (it does once the file list is in; a
# connection that drops earlier leaves it in its home): found by its destination argument
rootsh "runuser -u $ow -- bash -c 'cd / && sleep 600 | exec rsync --server -logDtprze.iLsfxCIvu --delete . $BI/' > /dev/null 2>&1 < /dev/null &"
T_UNTIL_STEP=0.5 t_until 10 eval '[ -n "$(rx)" ]'; rpid=$(rx)
check "L4a a hung rsync receiver of $ow for bravo's incoming/, still in / (pid ${rpid:-none})" \
  eval '[ -n "$rpid" ] && [ "$(rootsh "readlink /proc/$rpid/cwd")" = / ]'
stale_lease
tok=$(rootsh "$AG begin bravo other@laptop" 2> "$E/l4-begin.err" | sed -n 's/^token=//p')
check "L4b the stale lease is taken over (token ${tok:-none}; $(tr '\n' ' ' < "$E/l4-begin.err"))" test -n "$tok"
check "L4c and its receiver was ended first" eval '[ -n "$rpid" ] && ! alive "$rpid"'
[ -n "$tok" ] && echo "$tok" | rootsh "$AG end bravo" > /dev/null
rootsh "pkill -u $ow -x sleep; kill $dpid $apid; chown $ow0 $BI" 2> /dev/null
bravo_v "$v0"

# J: apps alpha (job tick, every 20 s), alpha-job (jobs tick, fail) and alpha-job-tick
jt() { echo "/etc/systemd/system/tando-$1_job-$2"; }
# a job's timer by what its file says (the form before or now): present and running
timer_of() { rootsh "grep -lx 'Description=tando job timer $1 $2' /etc/systemd/system/*.timer"; }
timer_ok() { local t; t=$(timer_of "$1" "$2") && [ "$(echo "$t" | wc -l)" -eq 1 ] && rootsh "systemctl -q is-active ${t##*/}"; }
AJ=$W/w/alpha-job; rm -rf "$AJ"; cp -R "$W/w/bravo" "$AJ"
conf_set "$AJ/tando.conf" app alpha-job
printf 'job.tick = *:*:0/20 | echo tick-of-alpha-job\njob.fail = yearly | false\n' >> "$AJ/tando.conf"
(cd "$AJ" && "$R" up > "$E/j-up.out" 2>&1) || { tail -5 "$E/j-up.out" >&2; fail "J0 up alpha-job"; }
check "J1 alpha's and alpha-job's job units are each their own" \
  eval 'rootsh "test -f $(jt alpha tick).timer && test -f $(jt alpha-job tick).timer && test -f $(jt alpha-job fail).service &&
    grep -qx \"ExecStart=$AG run-job alpha tick\" $(jt alpha tick).service && grep -qx \"ExecStart=$AG run-job alpha-job tick\" $(jt alpha-job tick).service" &&
    timer_ok alpha tick && timer_ok alpha-job tick'
# a deploy of alpha (its jobs follow the verified release) leaves alpha-job's timers alone
echo j2 > "$W/w/alpha/VERSION"
(cd "$W/w/alpha" && "$R" up > "$E/j2-up.out" 2>&1) || tail -5 "$E/j2-up.out" >&2
check "J2 a deploy of alpha leaves alpha-job's timers" eval 'timer_ok alpha-job tick && timer_ok alpha-job fail && timer_ok alpha tick'

# the units of the form before (tando-<app>-job-<name>, as the agent before wrote them, and
# alpha's glob tando-alpha-job-* matched alpha-job's): host setup renames each app's own
rootsh 'cd /etc/systemd/system && for a in alpha alpha-job; do for f in tando-${a}_job-*.service; do
    n=${f#tando-${a}_job-}; n=${n%.service}
    sed "/^TimeoutStartSec=/d" "$f" > "tando-$a-job-$n.service"; cp "tando-${a}_job-$n.timer" "tando-$a-job-$n.timer"
    systemctl disable -q --now "tando-${a}_job-$n.timer"; rm -f "$f" "tando-${a}_job-$n.timer"
    rm -f "/var/lib/systemd/timers/stamp-tando-${a}_job-$n.timer"
  done; done; systemctl daemon-reload
  systemctl enable -q --now tando-alpha-job-tick.timer tando-alpha-job-job-tick.timer tando-alpha-job-job-fail.timer
  touch -d "-1 hour" /var/lib/systemd/timers/stamp-tando-alpha-job-job-fail.timer'
# (a yearly job's last run an hour ago: a Persistent timer has nothing to catch up, so the stamp
# stays as it is unless the rename loses it)
st0=$(rootsh "date -r /var/lib/systemd/timers/stamp-tando-alpha-job-job-fail.timer +%s")
OLDJ="tando-alpha-job-tick tando-alpha-job-job-tick tando-alpha-job-job-fail"
check "J3a the old form is in place (alpha's tick and alpha-job's job-tick both match tando-alpha-job-*)" \
  rootsh "cd /etc/systemd/system && for u in $OLDJ; do test -f \$u.timer && test -f \$u.service || exit 1; done && ! ls | grep -q _job-"
"$R" host setup test public_port="$HP" > "$E/j3-setup.out" 2>&1 || tail -5 "$E/j3-setup.out" >&2
check "J3b host setup renamed every job unit, each to its own app's name" \
  eval 'rootsh "test -f $(jt alpha tick).timer && test -f $(jt alpha-job tick).timer && test -f $(jt alpha-job fail).timer &&
    cd /etc/systemd/system && for u in $OLDJ; do test ! -e \$u.timer && test ! -e \$u.service || exit 1; done" && timer_ok alpha tick && timer_ok alpha-job tick && timer_ok alpha-job fail'
check "J3c a renamed timer keeps its last run (its stamp, $st0)" \
  eval '[ -n "$st0" ] && [ "$(rootsh "date -r /var/lib/systemd/timers/stamp-tando-alpha-job_job-fail.timer +%s")" = "$st0" ]'

# tando jobs, tando jobs run and the alert address alpha-job's own units
"$R" jobs -a alpha-job > "$E/j4-jobs.out" 2>&1
check "J4a tando jobs -a alpha-job lists its jobs" eval 'grep -q "fail.*yearly" "$E/j4-jobs.out" && grep -q tick "$E/j4-jobs.out"'
"$R" jobs run tick -a alpha-job > "$E/j4-run.out" 2>&1; rc=$?
check "J4b tando jobs run tick -a alpha-job runs alpha-job's job (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q tick-of-alpha-job "$E/j4-run.out"'
"$R" jobs run fail -a alpha-job > "$E/j4-fail.out" 2>&1; rc=$?
srv 'sudo /opt/tando/bin/tando-watch run' > /dev/null 2>&1
check "J4c its failed job fires alpha-job's alert job.fail (rc=$rc), none of alpha's" \
  eval '[ $rc = 1 ] && rootsh "grep -qx alpha-job.job.fail.st=firing /var/lib/tando/watch/state && ! grep -q \"^alpha\.job\.fail\" /var/lib/tando/watch/state"'

# app alpha-job-tick: its service had the name of alpha's job tick (tando-alpha-job-tick)
AT=$W/w/alpha-job-tick; rm -rf "$AT"; cp -R "$W/w/bravo" "$AT"; conf_set "$AT/tando.conf" app alpha-job-tick
(cd "$AT" && "$R" up > "$E/j5-up.out" 2>&1); rc=$?
check "J5 app alpha-job-tick (rc=$rc) runs beside alpha's job tick" \
  eval '[ $rc = 0 ] && get alpha-job-tick | grep -q . && timer_ok alpha tick &&
    rootsh "grep -qx \"ExecStart=$AG run-job alpha tick\" $(jt alpha tick).service"'
# destroying alpha-job and alpha-job-tick leaves alpha's job complete
(cd "$AT" && echo alpha-job-tick | "$R" destroy --purge > "$E/j6-d1.out" 2>&1) || tail -3 "$E/j6-d1.out" >&2
(cd "$AJ" && echo alpha-job | "$R" destroy --purge > "$E/j6-d2.out" 2>&1) || tail -3 "$E/j6-d2.out" >&2
check "J6a alpha-job and alpha-job-tick are gone with their units" \
  rootsh '! test -d /opt/tando/apps/alpha-job && ! test -d /opt/tando/apps/alpha-job-tick && ! ls /etc/systemd/system | grep -q "^tando-alpha-job[_.-]"'
ltrig() { rootsh "systemctl show -P LastTriggerUSecMonotonic tando-alpha_job-tick.timer"; }
lt0=$(ltrig)
ticked() { [ "$(ltrig)" != "$lt0" ]; }
check "J6b alpha's job tick is complete after both destroys and still runs (its timer fires again)" \
  eval 'rootsh "test -f $(jt alpha tick).service" && timer_ok alpha tick && T_UNTIL_STEP=2 t_until 45 ticked'
