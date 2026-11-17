#!/bin/bash
# test/e2e-cli.sh: the argument handling of every command, without a server. For each command of
# lib/help.txt: `<cmd> --help`, `<cmd> -h` and `tando help <cmd>` print its help and exit 0;
# `<cmd> --bogus` and too many arguments are usage errors (exit 2) with the usage lines. ssh,
# rsync and scp are replaced by stubs that record every call: none of these may reach a server.
# Runs in a project directory (tando.conf, a registered host), so a command that ran anyway
# would try to connect and be caught. bash 3.2 compatible.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-cli   # work dir: test/.<suite>-<server>, or $T_WORK (all.sh)

# stubs first on PATH: they record the call and fail like an unreachable server
mkdir -p "$E/bin" "$E/w/hello"
for b in ssh rsync scp ssh-keyscan; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\necho "ssh: connect to host 127.0.0.1 port 9: Connection refused" >&2\nexit 255\n' \
    "$b" "$E" > "$E/bin/$b"
  chmod +x "$E/bin/$b"
done
export PATH="$E/bin:$PATH"
calls() { [ -f "$E/calls" ] && grep -c . "$E/calls" || echo 0; }
mkdir -p "$TANDO_CONFIG_DIR/hosts"
printf 'target=nobody@127.0.0.1\nport=9\nkey=\ninsecure=1\nkind=admin\n' > "$TANDO_CONFIG_DIR/hosts/vps"
printf 'app = hello\nhost = vps\nrecipe = node\nstart = node server.js\n' > "$E/w/hello/tando.conf"
echo 'require("http").createServer((q, s) => s.end("hi")).listen(process.env.PORT)' > "$E/w/hello/server.js"
cd "$E/w/hello" || exit 1

cmds=$(sed -n 's/^@@ \([a-z-]*\)$/\1/p' "$ROOT/lib/help.txt" | grep -v '^overview$')
n=0
for c in $cmds; do
  n=$((n + 1))
  for h in --help -h; do
    out=$("$R" "$c" "$h" 2>&1); rc=$?
    check "1$n$h $c $h prints its help and exits 0" \
      eval 'test $rc = 0 && printf "%s" "$out" | head -1 | grep -q "^usage: tando $c"'
  done
  out=$("$R" help "$c" 2>&1); rc=$?
  check "2$n tando help $c" eval 'test $rc = 0 && printf "%s" "$out" | grep -q "^usage: tando $c"'
  # --help after other arguments still only prints help (tando stop -a hello --help stops nothing)
  out=$("$R" "$c" -a hello --help 2>&1); rc=$?
  check "3$n $c -a hello --help prints help" eval 'test $rc = 0 && printf "%s" "$out" | grep -q "^usage:"'
  out=$("$R" "$c" --bogus 2>&1); rc=$?
  check "4$n $c --bogus is a usage error (exit 2) naming the flag" \
    eval 'test $rc = 2 && printf "%s" "$out" | grep -q "^tando: $c does not take --bogus" &&
          printf "%s" "$out" | grep -q "^usage: tando $c"'
  out=$("$R" "$c" x1 x2 x3 x4 x5 x6 2>&1); rc=$?
  case $c in env|alerts|host|ci) want="no subcommand\|wrong number";; *) want="takes no arguments\|takes at most\|wrong number\|no subcommand";; esac
  check "5$n $c with six extra arguments is a usage error (exit 2)" \
    eval 'test $rc = 2 && printf "%s" "$out" | grep -q "$want"'
done
check "6a none of the above reached a server (ssh/rsync calls: $(calls))" test "$(calls)" = 0

# leading flags, missing values, typos
out=$("$R" -H vps --help 2>&1); rc=$?
check "7a tando -H vps --help: the overview" eval 'test $rc = 0 && printf "%s" "$out" | grep -q "^Start here"'
out=$("$R" -a 2>&1); rc=$?
check "7b tando -a without a value: usage error" eval 'test $rc = 2 && printf "%s" "$out" | grep -q -- "-a needs a value"'
out=$("$R" status -a 2>&1); rc=$?
check "7c tando status -a without a value: names what is missing" \
  eval 'test $rc = 2 && printf "%s" "$out" | grep -q -- "-a needs an app name"'
out=$("$R" deplyo 2>&1); rc=$?
check "7d a typo suggests the command" eval 'test $rc = 2 && printf "%s" "$out" | grep -q "Did you mean \"deploy\""'
out=$("$R" staus 2>&1); rc=$?
check "7e staus -> status" eval 'test $rc = 2 && printf "%s" "$out" | grep -q "Did you mean \"status\""'
out=$("$R" frobnicate 2>&1); rc=$?
check "7f an unknown word: no wild guess" \
  eval 'test $rc = 2 && printf "%s" "$out" | grep -q "unknown command" && ! printf "%s" "$out" | grep -q "Did you mean"'
out=$("$R" 2>&1); rc=$?
check "7g tando alone: the overview fits one screen (<= 24 lines, < 80 columns)" \
  eval 'test $rc = 0 && test "$(printf "%s\n" "$out" | wc -l)" -le 24 && ! printf "%s\n" "$out" | grep -q ".\{80\}"'
out=$("$R" stop --watch 2>&1); rc=$?
check "7h stop --watch: refused (only views refresh)" eval 'test $rc = 2'
out=$("$R" status --watch x 2>&1); rc=$?
check "7i status --watch x: needs seconds" eval 'test $rc = 2 && printf "%s" "$out" | grep -q "needs seconds"'
out=$("$R" backup restore 2>&1); rc=$?
check "7j backup restore without an id: usage error" eval 'test $rc = 2'
out=$("$R" -H vps version 2>&1); rc=$?
check "7k global flags before the command work (tando -H vps version reaches for the server)" \
  eval 'printf "%s" "$out" | grep -q "^tando [0-9]"'
check "7l the only server contact so far is that version call ($(calls))" test "$(calls)" = 1
out=$("$R" status 2>&1); rc=$?
check "7m an unreachable server: one tando sentence with the next step, no raw ssh line" \
  eval 'test $rc != 0 && printf "%s" "$out" | grep -q "^tando: cannot reach vps" &&
        ! printf "%s" "$out" | grep -q "^ssh:"'
# N14: strip drops lone 8-bit C1 bytes (CSI 0x9b) and keeps UTF-8 text
got=$(printf 'a\233[2Jb \303\251 \302\233c\n' | (. "$ROOT/lib/common.sh"; strip) | LC_ALL=C od -An -tx1 | tr -d ' \n')
check "8a strip: a lone 0x9b is dropped, é kept, UTF-8 C1 becomes ? ($got)" t_eq "$got" "615b324a6220c3a9203f630a"
# N15: out must stay inside the project
printf 'app = hello\nhost = vps\nrecipe = static\nout = ../../etc\n' > "$E/w/hello/tando.conf.out"
out=$(cd "$E/w/hello" && mv tando.conf tando.conf.keep && cp tando.conf.out tando.conf && "$R" deploy 2>&1; mv tando.conf.keep tando.conf); rc=$?
check "8b out outside the project is refused" eval 'printf "%s" "$out" | grep -q "out must be a directory inside the project"'
# under /bin/bash (3.2 on macOS), with set -u: host setup with no settings, against an ssh that
# answers every call (an empty array expanded as "${a[@]}" was an "unbound variable" there)
mkdir -p "$E/okbin"
printf '%s\n' '#!/bin/sh' 'case "$*" in *"echo login=1"*) echo login=1; echo sudo=1;; *"uname -m"*) echo arch=aarch64;; esac' \
  'cat > /dev/null 2>&1 &' 'exit 0' > "$E/okbin/ssh"
chmod +x "$E/okbin/ssh"
out=$(cd "$E/w/hello" && PATH="$E/okbin:$PATH" /bin/bash "$R" host setup vps 2>&1); rc=$?
check "8c /bin/bash $(/bin/bash -c 'echo $BASH_VERSION' | cut -d. -f1-2): host setup with no settings runs through (rc=$rc)" \
  eval 'test $rc = 0 && ! printf "%s" "$out" | grep -q "unbound variable"'
out=$("$R" help exit-codes 2>&1); rc=$?
check "7n tando help <unknown> is an unknown command" eval 'test $rc = 2'
out=$("$R" help alerts notifier 2>&1); rc=$?
check "7o tando help <command> <sub> shows the command's help" \
  eval 'test $rc = 0 && printf "%s" "$out" | grep -q "^usage: tando alerts"'
# init: the port conventions (EXPOSE, Flask/FastAPI on $PORT, a Node app on a fixed port)
mkdir -p "$E/w/dock" "$E/w/flaskapp" "$E/w/fixport"
printf 'FROM nginx\nEXPOSE 8000/tcp\n' > "$E/w/dock/Dockerfile"
out=$(cd "$E/w/dock" && "$R" init 2>&1)
check "9a init: a Dockerfile's EXPOSE 8000 becomes container_port = 8000" \
  grep -q '^container_port = 8000$' "$E/w/dock/tando.conf"
printf 'from flask import Flask\napp = Flask(__name__)\napp.run()\n' > "$E/w/flaskapp/app.py"
echo flask > "$E/w/flaskapp/requirements.txt"
out=$(cd "$E/w/flaskapp" && "$R" init 2>&1)
check "9b init: Flask gets gunicorn bound to \$PORT, with the dependency note" \
  eval 'grep -q "^start = gunicorn -b 127.0.0.1:\$PORT app:app$" "$E/w/flaskapp/tando.conf" &&
        grep -q "^start_shell = true$" "$E/w/flaskapp/tando.conf" &&
        printf "%s" "$out" | grep -q "add gunicorn to requirements.txt"'
echo 'require("http").createServer((q, s) => s.end("hi")).listen(3000)' > "$E/w/fixport/server.js"
out=$(cd "$E/w/fixport" && "$R" init 2>&1)
check "9c init: a Node app on a fixed port is told to use process.env.PORT" \
  eval 'printf "%s" "$out" | grep -q "listens on a fixed port" && printf "%s" "$out" | grep -q "process.env.PORT"'
# init: a health route the project defines; / only with a note; Next without a config gets one
mkdir -p "$E/w/nexthealth/app/api/healthz" "$E/w/nodeplain" "$E/w/staticsite/public"
echo '{"dependencies":{"next":"15","pg":"8"}}' > "$E/w/nexthealth/package.json"
out=$(cd "$E/w/nexthealth" && "$R" init --yes < /dev/null 2>&1); rc=$?
check "9l init (Next): health = its /api/healthz route, next.config.mjs written, postgres suggested (rc=$rc)" \
  eval 'test $rc = 0 && grep -q "^health = /api/healthz$" "$E/w/nexthealth/tando.conf" &&
        grep -q "output: \"standalone\"" "$E/w/nexthealth/next.config.mjs" &&
        printf "%s" "$out" | grep -q "pg is a dependency: database = postgres"'
echo 'require("http").createServer((q, s) => s.end("hi")).listen(process.env.PORT)' > "$E/w/nodeplain/server.js"
out=$(cd "$E/w/nodeplain" && "$R" init < /dev/null 2>&1)
check "9m init without a health route: health = / and one line on how to add one" \
  eval 'grep -q "^health = /$" "$E/w/nodeplain/tando.conf" && printf "%s" "$out" | grep -q "no health route found"'
echo hi > "$E/w/staticsite/public/index.html"
out=$(cd "$E/w/staticsite" && "$R" init < /dev/null 2>&1)
check "9n init (static): no memory line, no start_shell example" \
  eval '! grep -q "memory" "$E/w/staticsite/tando.conf" && ! grep -q "start_shell" "$E/w/staticsite/tando.conf"'
# tando.conf parsing (fork-free trim): spaces and tabs around keys and values
printf '  app\t=  spaced  \nrecipe=static\n' > "$E/w/trim.conf"
got=$( (. "$ROOT/lib/ui.sh"; . "$ROOT/lib/common.sh"
  conf_load "$E/w/trim.conf" && printf '%s|%s' "$C_app" "$C_recipe") 2>&1)
check "9d conf_load trims keys and values ($got)" t_eq "$got" "spaced|static"
# a failure box's fix is wrapped at the box width, never cut with an ellipsis
got=$( (. "$ROOT/lib/ui.sh"; TANDO_ASCII=1; ui_init; . "$ROOT/lib/common.sh"; ui_box_open t
  box_say "" "  check the spelling, or use the IP address:" \
    "tando host add prod vmadmin@<ip> --force, then deploy again"; ui_box_close) 2>&1)
check "9e box_say wraps a long hint (all of it shown, no …, lines <= 80 columns)" \
  eval 'printf "%s" "$got" | grep -q "deploy again" && ! printf "%s" "$got" | grep -q "…" &&
        ! printf "%s\n" "$got" | LC_ALL=C grep -q ".\{81\}"'
# a view piped into head: nothing on stderr
# shellcheck disable=SC2034  # read by the eval below
err=$("$R" recipes 2>&1 > >(head -1 > /dev/null)); sleep 0.2
check "9f tando recipes | head -1: no broken-pipe message" eval '! printf "%s" "$err" | grep -q "Broken pipe"'
# the host is asked once: 2 servers, no host = in tando.conf, no terminal: a clear error naming -H
cp "$TANDO_CONFIG_DIR/hosts/vps" "$TANDO_CONFIG_DIR/hosts/vps2"
mkdir -p "$E/w/twohosts/public"; echo hi > "$E/w/twohosts/public/index.html"
printf 'app = twohosts\nrecipe = static\nout = public\n' > "$E/w/twohosts/tando.conf"
out=$(cd "$E/w/twohosts" && "$R" up < /dev/null 2>&1); rc=$?
check "9g up with 2 servers, no host = and no terminal: names -H (rc=$rc)" \
  eval 'test $rc = 1 && printf "%s" "$out" | grep -q "tando up -H <name>"'
out=$(cd "$E/w/twohosts" && "$R" up -H vps2 < /dev/null 2>&1)
check "9h up -H vps2 writes host = vps2 into tando.conf" grep -q '^host = vps2$' "$E/w/twohosts/tando.conf"
out=$("$R" ls --all --json 2>/dev/null)
check "9i ls --all --json: one JSON object, an unreachable server as an error" \
  eval 'printf "%s" "$out" | grep -q "^{\"hosts\":\[{\"host\":\"vps\",\"error\":\"" &&
        printf "%s" "$out" | python3 -c "import json,sys; json.load(sys.stdin)"'
rm -f "$TANDO_CONFIG_DIR/hosts/vps2"
# domain add --wait polls DNS (it was dropped by the global flag parser, so the wizard's
# `tando go --dns wait` stopped at once); a server that answers `info` only, a domain elsewhere
mkdir -p "$E/dnsbin"
printf '%s\n' '#!/bin/sh' 'case "$*" in *" info") printf "addrs=192.0.2.10\nip=192.0.2.10\ndomain_tls=auto\n";;' \
  '*) echo "ssh: connect to host 127.0.0.1 port 9: Connection refused" >&2; exit 255;; esac' > "$E/dnsbin/ssh"
chmod +x "$E/dnsbin/ssh"
out=$(PATH="$E/dnsbin:$PATH" TANDO_TEST_RESOLVE="late.test=203.0.113.9" "$R" domain add late.test 2>&1); rc=$?
check "9j domain add, DNS elsewhere, no --wait: stops at once with the record and the --wait command (rc=$rc)" \
  eval 'test $rc = 1 && printf "%s" "$out" | grep -qE "A +late.test +-> +192.0.2.10" &&
        printf "%s" "$out" | grep -q -- "--wait polls"'
PATH="$E/dnsbin:$PATH" TANDO_TEST_RESOLVE="late.test=203.0.113.9" "$R" domain add late.test --wait \
  > "$E/dnswait.out" 2>&1 & dp=$!
sleep 3
# shellcheck disable=SC2034 # read by the check below
if kill -0 $dp 2> /dev/null; then alive=1; else alive=0; fi
kill $dp 2> /dev/null; wait $dp 2> /dev/null
check "9k domain add --wait keeps polling (still running after 3 s, says it waits)" \
  eval 'test $alive = 1 && grep -q "waiting for DNS of late.test" "$E/dnswait.out"'
# error messages a newcomer meets: what is wrong, and the command to run instead
# m <id> <text> <regex> -- args...: tando args fails with a usage or plain error matching regex
# shellcheck disable=SC2034 # re and out are read by the eval in check
m() {
  local id=$1 text=$2 re=$3 out rc; shift 4
  out=$("$R" "$@" < /dev/null 2>&1); rc=$?
  check "$id $text (rc=$rc)" eval 'test $rc != 0 && printf "%s" "$out" | grep -qE -- "$re"'
}
# the app as a word (tando logs shop): it reaches the server as the app, -a still works, and
# where a command has words of its own the rule is fixed (lib/help.txt overview)
# ac <id> <text> <want in the ssh call> -- args...: the call tando made carries want
ac() {
  local id=$1 text=$2 want=$3; shift 4
  : > "$E/calls"
  (cd "$E/w/noconf" && "$R" "$@" < /dev/null > /dev/null 2>&1)
  check "$id $text" grep -q -- "$want" "$E/calls"
}
mkdir -p "$E/w/noconf"
ac P1 "restart shop: the agent restarts shop" "restart shop" -- restart shop -H vps
ac P2 "releases shop" "releases shop" -- releases shop -H vps
ac P3 "env ls shop: the app after the subcommand" "env-ls shop" -- env ls shop -H vps
ac P4 "logs shop -n 5 --since 1h: flags around the app" " shop" -- logs shop -n 5 --since 1h -H vps
ac P5 "rollback shop <id>" "rollback shop 20261113-171442" -- rollback shop 20261113-171442 -H vps
ac P6 "rollback <id> shop: either order" "rollback shop 20261113-171442" -- rollback 20261113-171442 shop -H vps
ac P7 "domain ls shop" "domain-ls shop" -- domain ls shop -H vps
ac P8 "-a shop still works (stop -a shop)" "stop shop" -- stop -a shop -H vps
ac P9 "requests tail shop" " shop" -- requests tail shop -H vps
m P10 "two different apps (-a and a word) are refused" 'two apps: -a one and two' -- restart -a one two
m P11 "env shop: the app goes after the subcommand" '"tando env ls shop"' -- env shop
m P12 "rollback with a malformed id says so" 'bad release id: 2026-11' -- rollback 2026-11
m P13 "an app word that is not an app name" 'not an app name: Shop' -- logs Shop
# server answers the client must read (a stub agent): env staged / not restarted, jobs run,
# rollback reasons in history at 80 columns
mkdir -p "$E/agentbin"
cat > "$E/agentbin/ssh" <<'STUB'
#!/bin/bash
case "$*" in
  *" env-set "*) cat > /dev/null; printf '%b' "$STUB_ENV";;
  *" job-run "*) printf 'log=hello from tick\nresult=%s\nstatus=%s\nsecs=2\n' "$STUB_JOB" "$STUB_RC";;
  *" history "*) printf 'hist\thello\t1763000000\t20261113-021000\tdeploy\trolledback\t31\t1\t0\t0\t1\t0\t20\tit exited with status 1, 20 s after going live: rolled back to 20261112-090000\n'
                 printf 'hist\thello\t1763000100\t20261113-021500\trollback\tok\t1\t0\t0\t0\t0\t1\t0\t-\n';;
  *) echo "ssh: connect to host 127.0.0.1 port 9: Connection refused" >&2; exit 255;;
esac
STUB
chmod +x "$E/agentbin/ssh"
sa() { (cd "$E/w/hello" && PATH="$E/agentbin:$PATH" "$R" "$@" < /dev/null 2>&1); }
out=$(STUB_ENV='changed=1\nstaged=1\n' sa env set A=1)
check "S1 env set before the first up: staged, applied by the first tando up" \
  eval 'printf "%s" "$out" | grep -q "staged for hello (not on vps yet): the first tando up applies it"'
out=$(STUB_ENV='changed=1\nrestarted=0\nwhy=stopped\n' sa env set A=1)
check "S2 env set on a stopped app: tando start uses it" eval 'printf "%s" "$out" | grep -q "hello is stopped: tando start uses it"'
out=$(STUB_ENV='changed=1\nrestarted=0\nwhy=nothing-deployed\n' sa env set A=1)
check "S3 env set, nothing deployed: the next deploy uses it" eval 'printf "%s" "$out" | grep -q "the next deploy uses it"'
out=$(STUB_JOB=success STUB_RC=0 sa jobs run tick); rc=$?
check "S4 jobs run tick: its output, then ok (rc=$rc)" \
  eval 'test $rc = 0 && printf "%s" "$out" | grep -q "^hello from tick$" && printf "%s" "$out" | grep -q "job tick: ok in 2s"'
out=$(STUB_JOB=exit-code STUB_RC=3 sa jobs run tick); rc=$?
check "S5 a failing job: result and exit status, tando exits with it (rc=$rc)" \
  eval 'test $rc = 3 && printf "%s" "$out" | grep -q "job tick: failed (exit-code, exit 3) in 2s"'
m S6 "jobs run with a bad name" 'bad job name: a/b' -- jobs run a/b -a hello
out=$(COLUMNS=80 sa history)
check "S7 history at 80 columns: the rollback reason whole, under the table" \
  eval 'printf "%s\n" "$out" | grep -q "why" &&
        printf "%s" "$out" | tr -d "│\n" | tr -s " " | grep -q "it exited with status 1, 20 s after going live: rolled back to 20261112-090000"'
out=$(COLUMNS=80 TZ=Asia/Jakarta sa history)
check "S7b history: TIME (GMT) is the UTC time (11-13 02:13), not the laptop's (TZ=Asia/Jakarta) or an age" \
  eval 'printf "%s" "$out" | grep -q "TIME (GMT)" && printf "%s" "$out" | grep -q "11-13 02:13 " &&
        ! printf "%s" "$out" | grep -qE " ago|11-13 09:13"'
# rsync splits -e on spaces: a TMPDIR with a space must not hold tando's work dir (ssh wrapper)
mkdir -p "$E/tmp dir"
out=$(TMPDIR="$E/tmp dir" sa history); rc=$?
check "S7c TMPDIR with a space: commands still work (rc=$rc)" \
  eval 'test $rc = 0 && printf "%s" "$out" | grep -q "TIME (GMT)"'
# sshd turns sessions away when too many share one connection (MaxSessions 10): the stub refuses
# the first two tries of each of 30 parallel commands; every one must still succeed, and one that
# is always refused names the cause
mkdir -p "$E/busybin" "$E/busy"; rm -f "$E/busy/"c.*
cat > "$E/busybin/ssh" <<'STUB'
#!/bin/bash
f=$BUSY_DIR/c.$BUSY_ID; n=$(cat "$f" 2> /dev/null || echo 0); echo $((n + 1)) > "$f"
if [ -n "${BUSY_ALWAYS:-}" ] || [ "$n" -lt 2 ]; then
  echo "mux_client_request_session: Session open refused by peer" >&2; exit 255
fi
printf 'hist\thello\t1763000000\t20261113-021000\tdeploy\tok\t31\t1\t0\t0\t1\t0\t20\t-\n'
STUB
chmod +x "$E/busybin/ssh"
for i in $(seq 1 30); do
  (cd "$E/w/hello" && BUSY_DIR=$E/busy BUSY_ID=$i PATH="$E/busybin:$PATH" "$R" history < /dev/null > "$E/busy/o.$i" 2>&1
   echo $? > "$E/busy/rc.$i") &
done
wait
bad=$(cat "$E/busy/"rc.* | grep -vc '^0$')
check "S7d 30 parallel commands, each refused twice by sshd MaxSessions, all succeed ($bad failed)" \
  eval 'test "$bad" = 0 && grep -l "20261113-021000" "$E/busy/"o.* | wc -l | grep -q "30"'
out=$(cd "$E/w/hello" && BUSY_DIR=$E/busy BUSY_ID=x BUSY_ALWAYS=1 PATH="$E/busybin:$PATH" "$R" history < /dev/null 2>&1); rc=$?
check "S7e a session that stays refused: one sentence that names the cause (rc=$rc)" \
  eval 'test $rc != 0 && printf "%s" "$out" | grep -q "too many tando commands at once to vps" &&
        test "$(cat "$E/busy/c.x")" = 4'
out=$(cd "$E/w/noconf" && "$R" ssh -- id 2>&1); rc=$?
check "S8 ssh -- cmd outside a project names the app form (rc=$rc)" \
  eval 'test $rc = 1 && printf "%s" "$out" | grep -q "tando ssh <app> -- <command>"'
m E1 "a mistyped flag names the right one" 'does not take --forse\. Did you mean --force\?' -- deploy --forse
m E2 "--follow on logs points at -f" 'Did you mean -f\?' -- logs --follow
m E3 "a flag before the command: the same line, command first" '^tando: -n goes after the command: tando history -n 5$' -- -n 5 history
m E4 "domain <name> without add: the add command" 'Did you mean "tando domain add example.com"\?' -- domain example.com
m E5 "domain add without a name says what is missing" '^tando: domain add needs <domain>$' -- domain add
m E6 "env add: env set" 'Did you mean "tando env set"\?' -- env add FOO=1
m E7 "host add with host:port: the port goes in --port" 'tando host add prod root@192.0.2.1 --port 2222$' -- host add prod root@192.0.2.1:2222
m E8 "host add without user@: the command with a user" 'tando host add prod root@192.0.2.1 ' -- host add prod 192.0.2.1
m E9 "an unknown host: how to register it" 'unknown host: nosuch \(servers here: vps.*tando host add nosuch <user@address>' -- status -H nosuch
m E10 "too many arguments: the most it takes" 'releases takes at most 1 argument \(got 2\)' -- releases ab cd
mkdir -p "$E/w/noconf"
out=$(cd "$E/w/noconf" && "$R" logs < /dev/null 2>&1); rc=$?
check "E11 no tando.conf here: names -a <app> with this command (rc=$rc)" \
  eval 'test $rc = 1 && printf "%s" "$out" | grep -q "tando logs -a <app>"'
out=$(cd "$E/w/noconf" && TANDO_CONFIG_DIR=$E/cfg-empty "$R" status < /dev/null 2>&1); rc=$?
check "E12 no server registered: tando go first (rc=$rc)" \
  eval 'test $rc = 1 && printf "%s" "$out" | grep -q "tando go <user@address>"'
# offsite backups and restore (lib/offsite.sh, lib/cmd-restore.sh): wrong words never reach the server
rm -f "$E/calls"
m O1 "backup offsite typo: the nearest subcommand" 'Did you mean "tando backup offsite status"' -- backup offsite stauts
m O2 "backup offsite set: a secret on the command line is refused" 'never given on the command line' -- backup offsite set secret_access_key=abc
m O3 "backup offsite set: an unknown setting" 'unknown setting: bukcet' -- backup offsite set bukcet=x
m O4 "backup offsite key without a flag" 'needs one of --show' -- backup offsite key
m O5 "backup offsite test takes no arguments" 'takes no arguments' -- backup offsite test now
m O6 "restore --from-host with a bad host id" 'bad host id' -- restore --from-host ../x --all
m O7 "restore --all without --from-host" '--all goes with --from-host' -- restore --all
m O8 "restore with a bad backup id" 'bad backup id: 2026-x' -- restore 2026-x
m O9 "restore --from-host: apps and --all together" 'not both' -- restore --from-host abcdef123456 shop --all
m O10 "restore --from-host takes a value" 'needs a value' -- restore --from-host
check "O11 none of the offsite cases reached a server ($(calls))" test "$(calls)" = 0
# none of the wrong inputs above or below ends in a shell error
: > "$E/shellerr"
for a in "deploy --forse" "-n 5 history" "domain add" "host add" "host setup" "backup pull x" "env set" \
    "status --watch" "logs -n" "-a" "-H" "go --domian x" "go root@192.0.2.1:22" "rollback a b c" \
    "help nosuch" "top" "domain add bad..name" "alerts notifer" "ci remove" "ls -all" \
    "backup offsite nope" "backup offsite key --rotat" "restore" "restore --from-host x"; do
  # shellcheck disable=SC2086 # the words of each case
  (cd "$E/w/noconf" && /bin/bash "$R" $a < /dev/null >> "$E/shellerr" 2>&1)
done
check "E13 wrong inputs under /bin/bash: no unbound variable, syntax error or bash line error" \
  eval '! grep -E "unbound variable|syntax error|command not found|line [0-9]+:" "$E/shellerr"'
t_done
