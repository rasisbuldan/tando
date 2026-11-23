#!/bin/bash
# test/e2e-sshmux.sh: a command never hangs on a dead or wedged shared ssh connection (the
# ControlPersist master). A `tando host setup` once sat for 15 minutes on an ssh call of a master
# that had outlived a night asleep and a reboot of the server. No ssh option bounds a mux client
# waiting on a master that is alive but silent, so lib/common.sh checks the master before the first
# command of a run (ssh_mux_heal) and watches every agent call (ssh_g, ssh_watchdog).
#   M1 a master started by a first call holds no stdin, stdout or stderr of its caller
#   M2 a master that does not answer (SIGSTOP) is dropped before the command: it runs on a new one
#   M3 the master stops answering while a call is running: the call is ended, not waited for
#   M4 the server stops answering (docker pause) during a call: it ends within ServerAlive's bound
# The server has a stub agent (no `tando host setup`: nothing here needs the real one). bash 3.2.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-sshmux
t_server_up --reset || exit 1
t_host_add test
"$SSH" 'sudo mkdir -p /opt/tando/bin && printf "%s\n" "#!/bin/sh" "case \$1 in sleep) sleep \$2; echo slept;; *) echo ok;; esac" | sudo tee /opt/tando/bin/tando-agent > /dev/null && sudo chmod 755 /opt/tando/bin/tando-agent' || exit 1

# bound <seconds> cmd...: run it in its own process group; killed after <seconds> (rc 124)
bound() {
  perl -e '$t = shift; $p = fork; if (!$p) { setpgrp(0, 0); exec @ARGV; exit 127 }
    $SIG{ALRM} = sub { kill 9, -$p; $to = 1 }; alarm $t; waitpid $p, 0; kill 9, -$p;
    exit($to ? 124 : $? >> 8)' "$@"
}
# abash <verb args...>: what a tando command does (agent_raw through ssh_g) on host "test"; a script,
# so each call is a new process as a new tando command is. Short watch times so the suite is quick.
cat > "$E/agent.sh" <<'EOS'
. "$TANDO_HOME/lib/ui.sh"; . "$TANDO_HOME/lib/common.sh"
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
host_use test && agent_raw "$@"
EOS
printf '#!/bin/bash\nSSH_WATCH=2 SSH_MUX_WAIT=2 TANDO_HOME=%s exec bash %s "$@"\n' "$ROOT" "$E/agent.sh" > "$E/abash"
chmod +x "$E/abash"; PATH=$E:$PATH:/usr/sbin:/usr/bin
# (the socket directory is short, /tmp/tando.XXXXXX, when the work directory's path is long: ctl-dir)
mux_re() { printf 'ssh: %s/.*\\[mux\\]' "$(cat "$TANDO_CONFIG_DIR/ctl-dir" 2> /dev/null || echo "$TANDO_CONFIG_DIR/cm")"; }
mux_pid() { pgrep -f "$(mux_re)" | head -1; }
mux_stop() { pkill -9 -f "$(mux_re)" 2> /dev/null; sleep 0.3; }
now_s() { perl -MTime::HiRes=time -e 'printf "%d\n", time'; }

# ---- M1: the first call makes the master; it keeps no descriptor of the caller's pipe
out=$(bound 60 "$E/abash" hello 2> "$E/m1.err"); rc=$?
p=$(mux_pid)
check "M1a the first call (no master yet) returns, a master stays (rc=$rc, master pid ${p:-none})" \
  eval '[ $rc = 0 ] && [ "$out" = ok ] && [ -n "$p" ]'
if command -v lsof > /dev/null 2>&1 && [ -n "$p" ]; then
  # fds 0-2 of the master are /dev/null: it cannot keep a caller's pipe open
  open=$(lsof -a -p "$p" -d 0,1,2 -Fn 2> /dev/null | sed -n 's/^n//p' | grep -vc '^/dev/null$')
  check "M1b the master's stdin, stdout and stderr are /dev/null ($open other)" test "$open" = 0
else skip "M1b lsof not available"; fi

# ---- M2: a master that does not answer, before the command
mux_stop; bound 60 "$E/abash" hello > /dev/null 2>&1; p=$(mux_pid)
kill -STOP "$p"
s=$(now_s); out=$(bound 60 "$E/abash" hello 2> "$E/m2.err"); rc=$?; d=$(( $(now_s) - s ))
check "M2a a stopped master: the command runs on a new connection (rc=$rc, ${d}s)" \
  eval '[ $rc = 0 ] && [ "$out" = ok ] && [ $d -lt 20 ]'
check "M2b ... and says the old connection was dropped" grep -q 'did not answer: dropped' "$E/m2.err"
kill -9 "$p" 2> /dev/null

# ---- M3: the master stops answering while the call runs
mux_stop; bound 60 "$E/abash" hello > /dev/null 2>&1; p=$(mux_pid)
( sleep 3; kill -STOP "$p" ) &
s=$(now_s); out=$(bound 90 "$E/abash" sleep 60 2> "$E/m3.err"); rc=$?; d=$(( $(now_s) - s ))
check "M3a a master wedged during a call: the call ends (rc=$rc, ${d}s; it was a 60 s call, watchdog at 2 s)" \
  eval '[ $rc != 0 ] && [ $rc != 124 ] && [ $d -lt 30 ]'
check "M3b ... with a sentence saying so" grep -q 'stopped answering' "$E/m3.err"
wait; kill -9 "$p" 2> /dev/null
s=$(now_s); out=$(bound 60 "$E/abash" hello 2> /dev/null); rc=$?
check "M3c the next command works at once (rc=$rc, $(( $(now_s) - s ))s)" eval '[ $rc = 0 ] && [ "$out" = ok ]'

# ---- M4: the server goes silent (a laptop on a dead network, a frozen server)
mux_stop; bound 60 "$E/abash" hello > /dev/null 2>&1
( sleep 3; docker pause "$T_NAME" > /dev/null ) &
s=$(now_s); out=$(bound 120 "$E/abash" sleep 100 2> "$E/m4.err"); rc=$?; d=$(( $(now_s) - s ))
docker unpause "$T_NAME" > /dev/null 2>&1; wait
check "M4a a silent server: the call ends within ServerAlive's 3 x 10 s (rc=$rc, ${d}s)" \
  eval '[ $rc != 0 ] && [ $rc != 124 ] && [ $d -lt 75 ]'
t_until 40 eval 'out=$(bound 30 "$E/abash" hello 2> /dev/null); [ "$out" = ok ]'
check "M4b the server back: the next command works" test "$out" = ok

t_done
