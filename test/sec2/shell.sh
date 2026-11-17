# test/sec2/shell.sh: sourced by test/e2e-sec2.sh after the setup. The sandboxed app shell
# (`tando ssh <app>`, agent verb `shell`) seen from inside, as the attacker alpha against bravo:
# it is alpha's user in alpha's sandbox, and nothing of bravo, Caddy's admin API or root is in
# reach. Every check runs through the admin's real client unless it says otherwise. bash 3.2.

# one command in alpha's shell (stdin closed); output and status in SO, SRC
sh_a() { SO=$(cd "$W/w/alpha" && "$R" ssh alpha -- "$@" < /dev/null 2>&1); SRC=$?; }
has() { printf '%s' "$SO" | grep -q "$1"; }
hasnt() { ! printf '%s' "$SO" | grep -q "$1"; }
BP=$(srv "sudo sed -n 's/^port=//p' /opt/tando/apps/bravo/app.conf")
AP=$(srv "sudo sed -n 's/^port=//p' /opt/tando/apps/alpha/app.conf")
BPID=$(srv "systemctl show -P MainPID tando-bravo")
log "app shell: alpha port $AP, bravo port $BP (pid $BPID)"

# identity, place, env, writable paths
sh_a 'echo "u=$(id -un) uid=$(id -u) nnp=$(sed -n "s/^NoNewPrivs:[[:space:]]*//p" /proc/self/status)"; echo "cwd=$(pwd -P)"; echo "cur=$(readlink -f /opt/tando/apps/alpha/current)"; echo "sec=$SECRET_A port=$PORT home=$HOME"'
log "shell says: $(printf '%s' "$SO" | tr '\n' ' ')"
check "SH1 the shell is alpha's user, not root, with no new privileges" has 'u=tando-alpha uid=[1-9][0-9]* nnp=1'
# shellcheck disable=SC2034 # cur is read inside the eval'd check
cwd=$(printf '%s' "$SO" | sed -n 's/^cwd=//p') cur=$(printf '%s' "$SO" | sed -n 's/^cur=//p')
check "SH2 its directory is alpha's current release ($cwd)" eval '[ -n "$cwd" ] && [ "$cwd" = "$cur" ]'
check "SH3 alpha's env is loaded, PORT is alpha's port, HOME is tando's" has "sec=alpha-secret-value port=$AP home=/opt/tando/apps/alpha/home"
sh_a 'touch "$TANDO_DATA_DIR/sh-probe" && rm "$TANDO_DATA_DIR/sh-probe" && echo SHARED-RW; touch ./sh-probe 2>/dev/null && echo REL-RW; touch /etc/sh-probe 2>/dev/null && echo ETC-RW; touch /opt/tando/sh-probe 2>/dev/null && echo OPT-RW; touch "$HOME/.npmrc" 2>/dev/null && echo HOME-RW; echo done'
check "SH4 shared/ is writable; HOME, the release, /etc and /opt/tando are not ($(printf '%s' "$SO" | tr '\n' ' '))" \
  eval 'has SHARED-RW && hasnt REL-RW && hasnt ETC-RW && hasnt OPT-RW && hasnt HOME-RW && has done'
sh_a 'sudo -n true 2>&1 && echo SUDO-OK; su -c true root < /dev/null 2>&1 && echo SU-OK; echo done'
check "SH5 no sudo, no su" eval 'hasnt SUDO-OK && hasnt SU-OK && has done'

# bravo's secrets and files
sh_a "cat /opt/tando/apps/bravo/env; cat /opt/tando/apps/bravo/shared/data/db.json; ls /opt/tando/apps/bravo/shared; cat /opt/tando/apps/bravo/current/server.js | head -c 300; cat /opt/tando/apps/bravo/app.conf /opt/tando/apps/bravo/state; cat /proc/$BPID/environ | tr '\\0' '\\n'; ls /proc/$BPID/root/ /proc/$BPID/cwd/; echo done"
check "SH6 bravo's env, data, release, metadata and process environment are unreadable" \
  eval 'hasnt bravo-secret-value && hasnt bravo-data-value && hasnt "createServer" && hasnt "^port=" && hasnt "^current=" && has done'
# (files under 100 MB: a09 leaves 1 GB files of zeros in alpha's releases, and grep reading one as
# a single line ran out of alpha's 192 MB and was OOM-killed, with no output at all)
# (the pattern is built at run time: the command line itself, in ps and in the transient unit file
# under /run/systemd/transient, is world-readable and must not match)
sh_a "p=bravo-secret; find /opt/tando /etc /run /var/lib/tando /var/backups /tmp /var/tmp /dev/shm -type f -size -100M -print0 2>/dev/null | xargs -0 grep -ls \"\$p-value\" 2>/dev/null | head -5; grep -ls \"\$p-value\" /proc/[0-9]*/environ 2>/dev/null | head -5; echo done"
check "SH7 no file alpha's shell can read holds bravo's secret ($(printf '%s' "$SO" | grep -v '^done' | head -3 | tr '\n' ' '))" \
  eval '[ "$(printf "%s" "$SO" | grep -v "^done$" | grep -c .)" = 0 ] && has done'

# ports: no bind at all (bravo's, bravo's pre-flight, any), no connection to bravo's
bindjs='const p=+process.argv[1];require("net").createServer().on("error",e=>{console.log("p"+p+"="+e.code);process.exit(0)}).listen(p,"127.0.0.1",()=>{console.log("p"+p+"=BOUND");process.exit(0)})'
sh_a "for p in $BP $((BP + 100)) 0 18080; do node -e '$bindjs' \$p; done"
log "binds: $(printf '%s' "$SO" | tr '\n' ' ')"
check "SH8 alpha's shell cannot bind bravo's port, its pre-flight port or any port (EPERM)" \
  eval 'hasnt BOUND && [ "$(printf "%s" "$SO" | grep -cE "=(EPERM|EACCES)\$")" = 4 ]'
sh_a "curl -s -m 3 -o /dev/null -w 'own=%{http_code}\n' http://127.0.0.1:\$PORT/health; curl -s -m 3 -o /dev/null -w 'bravo=%{http_code}\n' http://127.0.0.1:$BP/ || echo bravo-unreachable"
check "SH9 it reaches alpha's own port but not bravo's ($(printf '%s' "$SO" | tr '\n' ' '))" \
  eval 'has "own=200" && has bravo-unreachable && hasnt "bravo=200"'

# Caddy's admin API
sh_a "curl -s -m 3 --unix-socket /run/caddy/admin.sock http://x/config/ && echo SOCK-OK; ls /run/caddy 2>/dev/null && echo LS-OK; curl -s -m 3 http://127.0.0.1:2019/config/ && echo TCP-OK; echo done"
check "SH10 Caddy's admin socket (and 127.0.0.1:2019) are out of reach" \
  eval 'hasnt SOCK-OK && hasnt LS-OK && hasnt TCP-OK && has done'

# status, stdin, terminal
sh_a 'exit 7'
check "SH11 a command's exit status is tando's (got $SRC)" t_eq "$SRC" 7
SO=$(cd "$W/w/alpha" && printf 'piped-in\n' | "$R" ssh alpha -- 'tr a-z A-Z' 2>&1)
check "SH12 stdin reaches the command" t_eq "$SO" PIPED-IN
python3 - "$R" "$W/w/alpha" > "$E/shell-pty.out" 2>&1 <<'PY' &
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.chdir(sys.argv[2]); os.execv(sys.argv[1], [sys.argv[1], "ssh", "alpha"])
out, sent, t0 = b"", False, time.time()
while time.time() - t0 < 40:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        out += d
    if not sent and (b"alpha:" in out or time.time() - t0 > 8):
        os.write(fd, b"echo \"I=$(id -un) T=$(tty) D=$(pwd -P)\"; echo SHELL-$((40+2))\r"); time.sleep(1); os.write(fd, b"exit\r"); sent = True
sys.stdout.write(out.decode("utf-8", "replace"))
PY
wait $!
SO=$(cat "$E/shell-pty.out")
check "SH13 tando ssh alpha opens an interactive shell on a terminal as tando-alpha" \
  eval 'has "I=tando-alpha T=/dev/pts/[0-9]* D=/opt/tando/apps/alpha/releases/" && has SHELL-42'
[ "$T_FAIL" = 0 ] || sed 's/^/  pty| /' "$E/shell-pty.out" | tail -20 >&2

# admin only: a deploy key never reaches the verb (tando-gate); the client refuses one too
o=$(ka "sudo -n $AG shell alpha" 2>&1; ka "$AG shell alpha 6964" 2>&1; ka "sudo -n $AG shell bravo" 2>&1; echo "rc=$?")
check "SH14 tando-gate refuses shell to alpha's deploy key ($(printf '%s' "$o" | head -1))" \
  eval '[ "$(printf "%s" "$o" | grep -c "not allowed with a deploy key: shell")" = 3 ] && ! printf "%s" "$o" | grep -q "tando-alpha\|uid="'
o=$(cd "$W/w/alpha" && TANDO_DEPLOY_KEY=$(cat "$KA") TANDO_HOST=127.0.0.1 TANDO_PORT=$SP CI=true TANDO_KNOWN_HOSTS="$(secret "$W/setup.alpha" TANDO_KNOWN_HOSTS)" TANDO_CONFIG_DIR=$W/cfg-ci "$R" ssh alpha -- id < /dev/null 2>&1)
check "SH15 the client refuses tando ssh with a deploy key" eval 'printf "%s" "$o" | grep -q "not a deploy key" && ! printf "%s" "$o" | grep -q "uid="'
o=$(ka "sudo -n /opt/tando/bin/tando-gate root alpha shell" 2>&1 < /dev/null; echo "rc=$?")
check "SH16 the gate's root mode has no shell either" eval '! printf "%s" "$o" | grep -q "uid=\|tando-alpha"'

# names and commands are validated by the agent itself (as root, over the admin's sudo)
bad=0
for n in '../bravo' 'bravo/../alpha' 'Alpha' 'alpha;id' 'a' '-p' 'alpha bravo' "$(printf 'alpha\nid')" \
         'abcdefghijklmnopqrstuvwxyz0' '' '.' 'tando-alpha'; do
  o=$(srv "sudo -n /opt/tando/bin/tando-agent shell $(printf '%q' "$n") 6964 < /dev/null" 2>&1); rc=$?
  case $o in *"invalid app name"*|*"no such app"*) [ $rc != 0 ] || bad=$((bad + 1));; *) bad=$((bad + 1)); log "name '$n' -> rc=$rc $o";; esac
  printf '%s' "$o" | grep -q 'uid=' && bad=$((bad + 1))
done
check "SH17 bad app names are refused before anything runs ($bad wrong)" t_eq "$bad" 0
bad=0
for h in zz 6 00 696400 0a69640a 69642 'XX' '' 6g "$(printf '%08194d' 0 | tr 0 a)"; do
  o=$(srv "sudo -n /opt/tando/bin/tando-agent shell alpha $h < /dev/null" 2>&1); rc=$?
  { [ $rc != 0 ] && ! printf '%s' "$o" | grep -q 'uid='; } || { bad=$((bad + 1)); log "hex '${h:0:20}' -> rc=$rc $o"; }
done
check "SH18 malformed, NUL, control-character and oversized commands are refused ($bad wrong)" t_eq "$bad" 0
# the longest command (8192 hex digits) costs the agent little CPU: a regex with {1,4096} took
# 4 s of CPU to compile on a small server (2 s here). CPU of the agent and its children, not wall time.
c='echo SHELL-OK; : '; c=$c$(printf '%04096d' 0 | tr 0 a); c=${c:0:4096}
h=$(printf '%s' "$c" | od -An -v -tx1 | tr -d ' \n')
o=$(srv "sudo bash -c '/opt/tando/bin/tando-agent shell alpha $h < /dev/null 2>&1; times'" 2>&1)
cpu=$(printf '%s\n' "$o" | tail -1 | awk '{ for (i = 1; i <= 2; i++) { split($i, t, "m"); s += t[1] * 60 + t[2] } } END { printf "%.2f", s }')
check "SH22 a one-shot of ${#h} hex digits runs and costs the agent ${cpu}s of CPU (limit 1 s)" \
  eval 'printf "%s" "$o" | grep -q "^SHELL-OK" && [ -n "$cpu" ] && awk -v c="$cpu" "BEGIN { exit !(c < 1) }"'
o=$(cd "$W/w/alpha" && "$R" ssh 'bravo;id' -- id < /dev/null 2>&1; echo "rc=$?")
check "SH19 the client refuses a bad app name" eval 'printf "%s" "$o" | grep -q "bad app name" && ! printf "%s" "$o" | grep -q "uid="'
check "SH20 every shell is in the audit log" srv 'sudo grep -q "shell.*alpha" /var/log/tando/audit.log'
check "SH21 no shell unit is left behind" eval '[ -z "$(srv "systemctl list-units --all --plain --no-legend \"tando-alpha-shell-*\"")" ]'
