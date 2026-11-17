#!/bin/bash
# test/e2e-trial.sh: what the first trial on a real server found, on a server as it was there:
# Caddy installed from its package and running with its default admin API on localhost:2019.
#   T1 host add of a server whose host key is already in the user's own ~/.ssh/known_hosts (tando
#      has no known_hosts of its own yet): saved, no question; a failed add always says why.
#   T2 host setup moves Caddy's admin API to its unix socket without restarting Caddy.
#   T3 doctor at 80 columns: no detail cut with "…", no command broken across lines.
# Run once more with TANDO_TEST_CADDY=ubuntu (the distribution's Caddy 2.6.2). bash 3.2 compatible.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-trial   # work dir: test/.<suite>-<server>, or $T_WORK (all.sh)
srv() { "$SSH" "$@"; }
t_server_up --reset || exit 1

# ---- T1. host add with the key in ~/.ssh/known_hosts ---------------------------------------------
# a fake HOME holds that known_hosts. ssh finds ~ in the password database, not in $HOME, so
# wrappers on PATH point ssh and ssh-keygen -F at $HOME/.ssh/known_hosts as they would at ~.
H=$E/home B=$E/bin
mkdir -p "$H/.ssh" "$B"
ssh-keyscan -p "$T_SSH_PORT" -t ed25519 127.0.0.1 2> /dev/null | grep -v '^#' > "$H/.ssh/known_hosts"
cat > "$B/ssh" <<EOF
#!/bin/bash
case " \$* " in *UserKnownHostsFile*) exec $(command -v ssh) "\$@";; esac
exec $(command -v ssh) -o "UserKnownHostsFile=\$HOME/.ssh/known_hosts" "\$@"
EOF
cat > "$B/ssh-keygen" <<EOF
#!/bin/bash
case " \$* " in *" -F "*) case " \$* " in *" -f "*) ;; *) set -- "\$@" -f "\$HOME/.ssh/known_hosts";; esac;; esac
exec $(command -v ssh-keygen) "\$@"
EOF
chmod +x "$B/ssh" "$B/ssh-keygen"
# said_why file: when the output has "(not saved", a line saying why comes before it
said_why() { awk '/\(not saved/ { if (prev == "") bad = 1 } NF { prev = $0 } END { exit bad }' "$1"; }

HOME=$H PATH=$B:$PATH "$R" host add test vmadmin@127.0.0.1 --port "$T_SSH_PORT" \
  --key "$ROOT/test/server/id_test" < /dev/null > "$E/add.out" 2>&1; rc=$?; cat "$E/add.out" >&2
check "T1a host add: the key known from ~/.ssh/known_hosts is enough, entry saved (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "added host test" "$E/add.out" && grep -qx insecure=0 "$TANDO_CONFIG_DIR/hosts/test" &&
        [ ! -f "$TANDO_CONFIG_DIR/known_hosts" ]'
check "T1b a failed host add still says why before \"(not saved\"" said_why "$E/add.out"
# nothing listens on port 1: the reason comes first
"$R" host add closed vmadmin@127.0.0.1 --port 1 --key "$ROOT/test/server/id_test" < /dev/null > "$E/add2.out" 2>&1; rc=$?
cat "$E/add2.out" >&2
check "T1c host add to a closed port fails with a reason before \"(not saved\" (rc=$rc)" \
  eval '[ $rc != 0 ] && grep -q "(not saved" "$E/add2.out" && said_why "$E/add2.out"'

# ---- T2. host setup moves the admin API without a restart ----------------------------------------
pid0=$(srv 'systemctl show -P MainPID caddy')
check "T2a before setup Caddy listens on 2019 (pid $pid0)" srv 'ss -Hltn "sport = :2019" | grep -q .'
HOME=$H PATH=$B:$PATH "$R" host setup test public_port="$T_HTTP_PORT" > "$E/setup.out" 2>&1; rc=$?
cat "$E/setup.out" >&2
pid1=$(srv 'systemctl show -P MainPID caddy')
check "T2b host setup works over that entry (rc=$rc)" t_eq "$rc" 0
check "T2c Caddy was not restarted (MainPID $pid0 -> $pid1)" eval '[ -n "$pid0" ] && [ "$pid0" != 0 ] && [ "$pid0" = "$pid1" ]'
# (an empty Host: Caddy 2.6.2 refuses any other on the socket)
check "T2d the admin socket answers; nothing listens on 2019" \
  srv 'sudo curl -sf -m 5 -H "Host: " --unix-socket /run/caddy/admin.sock http://localhost/config/ > /dev/null && ! ss -Hltn "sport = :2019" | grep -q .'
check "T2e systemctl reload caddy works afterwards" \
  srv 'sudo systemctl reload caddy && systemctl -q is-active caddy && test "$(systemctl show -P MainPID caddy)" = '"$pid1"

# ---- T3. doctor at 80 columns --------------------------------------------------------------------
# a changed tando-watch gives a warning whose command fell at the end of a line on the trial server
srv 'sudo cp -p /opt/tando/bin/tando-watch /opt/tando/bin/tando-watch.trial && echo "# trial" | sudo tee -a /opt/tando/bin/tando-watch > /dev/null'
t_pty 80 40 30 env HOME="$H" PATH="$B:$PATH" "$R" doctor test > "$E/doctor.out" 2>&1
srv 'sudo mv -f /opt/tando/bin/tando-watch.trial /opt/tando/bin/tando-watch'
perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\r//g' "$E/doctor.out" >&2
check "T3a doctor fits 80 columns" t_assert_width "$E/doctor.out" 80
check "T3b no ok row is cut with … (a warning is whole under the table)" eval '! grep "● ok" "$E/doctor.out" | grep -q "…"'
check "T3c the warning's command is whole, on a line of its own" \
  eval 'perl -pe "s/\e\[[0-9;?]*[A-Za-z]//g; s/\r//g" "$E/doctor.out" | grep -qE "^│ +tando host setup test +│\$"'
t_done
