#!/bin/bash
# m5: env before the first deploy, env during a soak, env on an app with nothing live, the hint
# for a missing env variable, and `job-run` (run a scheduled job now). Expect: a required secret
# can be set before `up` (staged, applied by the first configure); env set during a soak says
# what it waits for; nothing claims a restart that did not happen; a job runs in its own sandbox
# with its output and exit status shown.
. "$(dirname "$0")/lib-fault.sh"
f_init m5 "env before up / during soak, jobs run now" "env, job-run"
AG=/opt/tando/bin/tando-agent
gone() { srv "sudo test -d /opt/tando/apps/$1" 2> /dev/null && echo "$1" | (cd "$W" && "$R" destroy -a "$1" --purge > /dev/null 2>&1); true; }
A=fm5a B=fm5b; gone $A; gone $B; srv "sudo rm -rf /opt/tando/staged/$A /opt/tando/staged/$B"

# ---- a first deploy that needs NEED, without it: fails, and says which variable and how
f_app $A
deploy $A 1 needenv up
ok "the first up without NEED fails (rc=$DRC)" test "$DRC" != 0
ok "it names the missing variable and tando env set" grep -q 'environment variable NEED.*\|tando env set NEED=' "$W/$A.d1.out"
sed 's/^/    | /' "$W/$A.d1.out" | tail -8 >&2
o=$(printf 'NEED=now-set\n' | srv "sudo $AG env-set $A")
ok "env set on an app with nothing live says it did not restart ($(echo $o))" \
  sh -c "printf '%s' '$o' | grep -q 'restarted=0' && printf '%s' '$o' | grep -q 'why=nothing-deployed'"
deploy $A 2 needenv
ok "with NEED set the next deploy works (rc=$DRC)" sh -c "[ $DRC = 0 ] && [ \"\$(curl -s -m 5 $(url $A))\" = v2 ]"

# ---- a required secret set before the app exists: staged, applied by the first up
(cd "$W" && "$R" env set NEED=staged-first -a $B -H test) > "$W/stage.out" 2>&1; rc=$?
ok "env set before the app exists works (rc=$rc)" test $rc = 0
# lint: allow RL02 stat runs on the server (GNU)
ok "the staged value is root's only" srv "sudo stat -c %U:%a /opt/tando/staged/$B/env | grep -qx root:600 && sudo stat -c %a /opt/tando/staged/$B | grep -qx 700"
(cd "$W" && "$R" env ls -a $B -H test) > "$W/stage-ls.out" 2>&1
ok "env ls shows the staged key" grep -q NEED "$W/stage-ls.out"
o=$(printf 'X=1\n' | srv "sudo $AG env-set $B")
ok "the agent says staged, not restarted" sh -c "printf '%s' '$o' | grep -q staged=1 && printf '%s' '$o' | grep -q restarted=0"
# (soak = 20 in tando.conf wins over TANDO_SOAK and FAULT_SETUP_SOAK, for next_deploy too. Kept:
# the env set below must find a release soaking.)
f_app $B 'job.hi = daily | echo "hello-from-job $(id -un)"; echo err-from-job >&2; exit 3' "soak = 20"
deploy $B 1 needenv up
ok "the first up with the staged NEED works (rc=$DRC)" sh -c "[ $DRC = 0 ] && [ \"\$(curl -s -m 5 $(url $B))\" = v1 ]"
ok "the staged values became the app's env (root:tando-$B 640) and the stage is gone" \
  srv "sudo grep -q '^NEED=\"staged-first\"' /opt/tando/apps/$B/env && sudo grep -q '^X=' /opt/tando/apps/$B/env && [ \"\$(sudo stat -c %U:%G:%a /opt/tando/apps/$B/env)\" = root:tando-$B:640 ] && ! sudo test -e /opt/tando/staged/$B"

# ---- env set while a release soaks: the client says what it waits for (agent_wait + busy)
TANDO_WAIT="" deploy $B 2 needenv
id=$(rid "$W/$B.d2.out")
cat > "$W/aw.sh" <<DRV
#!/bin/bash
# the client's env call through agent_wait, as bin/tando would make it (lib/deploy.sh)
set -u
TANDO_HOME=$ROOT
. "\$TANDO_HOME/lib/ui.sh"; . "\$TANDO_HOME/lib/common.sh"; . "\$TANDO_HOME/lib/build.sh"; . "\$TANDO_HOME/lib/deploy.sh"
TMPD=\$(mktemp -d); trap 'rm -rf "\$TMPD"' EXIT
ui_init
APP=$B HOST=test ARGS=() FORCE="" YES="" JSON="" RESOLVED=""
resolve 1
printf 'LATE=1\n' | agent_wait sudo env-set "\$APP" > "\$TMPD/o"
cat "\$TMPD/o"
DRV
t0=$(date +%s)
(cd "$W" && bash "$W/aw.sh") > "$W/aw.out" 2> "$W/aw.err"; rc=$?
t1=$(date +%s)
log "env set during the soak: rc=$rc in $((t1 - t0)) s: $(cat "$W/aw.err" | tr '\n' ' ')"
ok "it said it waits for the soak of $id, with about how long" grep -q "waiting for the soak of release $id: about [0-9]*s more; then env-set runs" "$W/aw.err"
ok "then it ran and restarted the app (rc=$rc)" sh -c "[ $rc = 0 ] && grep -q restarted=1 '$W/aw.out'"
ok "the soaked release stayed (no rollback by the env change)" sh -c "[ \"\$(curl -s -m 5 $(url $B))\" = v2 ]"

# ---- job-run: the job's own unit and sandbox, output and exit status
srv "sudo $AG job-run $B hi" > "$W/job.out" 2>&1
sed 's/^/    | /' "$W/job.out" >&2
ok "job-run shows the job's output, as the app's user" grep -q "^log=hello-from-job tando-$B\$" "$W/job.out"
ok "and its stderr, without systemd's own lines" sh -c "grep -qx 'log=err-from-job' '$W/job.out' && ! grep -q '^log=.*\(Started\|Finished\|Deactivated\|Main process\)' '$W/job.out'"
srv "sudo $AG job-run $B hi" > "$W/job2.out" 2>&1
ok "a second run shows its own output once (not the first run's)" sh -c "[ \"\$(grep -c '^log=hello-from-job' '$W/job2.out')\" = 1 ]"
ok "and its exit status" sh -c "grep -qx status=3 '$W/job.out' && grep -qx result=exit-code '$W/job.out'"
o=$(srv "sudo $AG job-run $B nosuch; sudo $AG job-run $B '../x'; sudo $AG job-run ../$B hi" 2>&1)
ok "unknown jobs and bad names are refused" sh -c "[ \"\$(printf '%s' \"\$1\" | grep -c 'has no job\|invalid app name')\" = 3 ]" _ "$o"
o=$(srv "sudo -u nobody $AG job-run $B hi" 2>&1)
ok "job-run needs root" sh -c "printf '%s' \"\$1\" | grep -q 'needs root\|sudo'" _ "$o"
# ---- activate with a lease another deploy holds now, or with one that is gone: said plainly
tok=$(srv "sudo $AG begin $B m5-other < /dev/null" | sed -n 's/^token=//p')
o=$(printf '00000000-0000-4000-8000-000000000000\n' | srv "sudo $AG activate $B 0 0" 2>&1)
ok "a lease taken by another deploy says so ($o)" sh -c "printf '%s' \"\$1\" | grep -q 'another deploy of $B started while this one was uploading'" _ "$o"
printf '%s\n' "$tok" | srv "sudo $AG end $B" > /dev/null
o=$(printf '%s\n' "$tok" | srv "sudo $AG activate $B 0 0" 2>&1)
ok "a lease that is gone says expired ($o)" sh -c "printf '%s' \"\$1\" | grep -q \"lease expired; run the deploy again\"" _ "$o"
truth $B 2
next_deploy $B 3
f_end
