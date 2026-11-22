#!/bin/bash
# End-to-end test of restricted CI deploys (tando ci, server/tando-gate) against a throwaway
# server: TANDO_TEST_NAME (default tando-test-ci), TANDO_TEST_SSH_PORT (2301), TANDO_TEST_HTTP_PORT
# (8301). One PASS/FAIL line per check; exits non-zero on any failure. The attack section (6) runs
# every attempt with app alpha's key against app bravo and root; each must fail closed. A known
# hole is a FAIL, never a skipped check.
#
# lint: file-allow RL06 every /tmp path here is on the throwaway server or in a container (attack payloads, rsync options under test), never the laptop's /tmp
# The server is reset only when it is the default tando-test-ci or TANDO_TEST_OWNED=1; otherwise
# the suite reuses it and removes its own apps (alpha, bravo, charlie) first. Work directory:
# ${T_WORK:-test/.e2e-ci-<server>}. It runs this checkout; when bin/tando does not yet carry
# docs/ci-integration.patch, it runs a copy in the work directory with the patch applied.
# Needs: Docker (OrbStack), ruby (YAML), node/npm on the laptop. Builds the image
# tando-ci-runner:test (ubuntu:24.04 with GNU rsync 3.2.7 as on GitHub's runners; needs the Ubuntu
# mirror once) and pulls rhysd/actionlint:1.7.7 (Docker Hub) if missing; nothing else leaves the
# machine. Secrets reach containers as mounted files, never on a command line.
# Usage: test/e2e-ci.sh [--no-reset]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
. "$ROOT/test/lib.sh"   # t_until (this suite keeps its own pass/fail/check, defined below)
export TANDO_TEST_NAME=${TANDO_TEST_NAME:-tando-test-ci} TANDO_TEST_SSH_PORT=${TANDO_TEST_SSH_PORT:-2301}
export TANDO_TEST_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-8301}
SP=$TANDO_TEST_SSH_PORT HP=$TANDO_TEST_HTTP_PORT TN=$TANDO_TEST_NAME
E=${T_WORK:-$ROOT/test/.e2e-ci-$TN}
case $E in /*) ;; *) E=$ROOT/$E;; esac
SSH=$ROOT/test/server/ssh.sh
export TANDO_CONFIG_DIR=$E/cfg TANDO_COLOR=never
export TANDO_SOAK=${TANDO_SOAK:-2} TANDO_WAIT=1   # a short soak (30 s by default) keeps the suite fast
export GIT_CEILING_DIRECTORIES=$E   # the work repositories are not tando' own
unset TANDO_DEPLOY_KEY TANDO_HOST TANDO_PORT TANDO_KNOWN_HOSTS TANDO_PLAIN CI GITHUB_ACTIONS
FAILS=0 PASSES=0

pass() { echo "PASS $*"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
skip() { echo "SKIP $*"; }
check() { local n=$1; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
log() { echo "---- $*" >&2; }
srv() { "$SSH" "$@"; }
get() { curl -s -m 3 "http://$1.localhost:$HP${2:-/}"; }
ver() { get "$1" | sed -n 's/^hello v\([^ ]*\) .*/\1/p'; }
has() { grep -q -- "$2" "$1"; }
hasnt() { ! grep -q -- "$2" "$1"; }
secret() { awk -v n="--- $2" '$0 == n { on = 1; next } /^--- / { on = 0 } on' "$1"; }
conf_set() { grep -v "^$2 *=" "$1" > "$1.tmp"; [ -n "$3" ] && echo "$2 = $3" >> "$1.tmp"; mv "$1.tmp" "$1"; }

# key-based ssh as a deploy user, no ControlMaster, no agent
KOPTS=(-F /dev/null -p "$SP" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes
       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
kssh() { local k=$1 u=$2; shift 2; ssh "${KOPTS[@]}" -i "$k" "$u@127.0.0.1" "$@"; }
krsync() { local k=$1; shift; rsync -e "ssh ${KOPTS[*]} -i $k" "$@"; }
ka() { kssh "$KA" tando-d-alpha "$@"; }       # app alpha's key
AG=/opt/tando/bin/tando-agent INC=/opt/tando/apps/alpha/incoming/
begin_a() { ka "sudo -n $AG begin alpha x" 2> /dev/null | sed -n 's/^token=//p'; }
end_a() { ka "sudo -n $AG end alpha $1" > /dev/null 2>&1; }
# as_key <setup output> <command...>: run tando with that deploy key from the environment
as_key() {
  local f=$1; shift
  (
    TANDO_DEPLOY_KEY=${TANDO_KEYFILE:-$(secret "$f" TANDO_DEPLOY_KEY)}
    TANDO_HOST=$(secret "$f" TANDO_HOST) TANDO_PORT=$(secret "$f" TANDO_PORT)
    TANDO_KNOWN_HOSTS=$(secret "$f" TANDO_KNOWN_HOSTS) TANDO_CONFIG_DIR=$E/cfg-ci
    export TANDO_DEPLOY_KEY TANDO_HOST TANDO_PORT TANDO_KNOWN_HOSTS TANDO_CONFIG_DIR
    "$@"
  )
}
# refused <name> <command...>: the command must fail (fail closed)
refused() { local n=$1; shift; if "$@" > "$E/out" 2>&1; then fail "$n (it succeeded: $(tail -1 "$E/out"))"; else pass "$n"; fi; }
# refused_by <name> <regex> <command...>: must fail, and the output must give that reason
refused_by() { local n=$1 re=$2; shift 2
  if "$@" > "$E/out" 2>&1; then fail "$n (it succeeded: $(tail -1 "$E/out"))"
  elif grep -Eq -- "$re" "$E/out"; then pass "$n"
  else fail "$n (failed for another reason: $(tail -1 "$E/out" | cut -c1-90))"; fi; }
# srv_no <cmd>: the remote command fails (non-zero), and ssh itself worked (not 255)
srv_no() { srv "$@" > "$E/out" 2>&1; local rc=$?; [ $rc -ne 0 ] && [ $rc -ne 255 ]; }
# denied_as <user> <name> <command...>: run on the server as that user (as if it had code
# execution); the command must fail
denied_as() { local u=$1 n=$2 rc; shift 2
  srv "sudo -u $u $*" > "$E/out" 2>&1; rc=$?
  if [ $rc = 0 ]; then fail "$n (it succeeded: $(tail -1 "$E/out"))"
  elif [ $rc = 255 ]; then fail "$n (ssh failed, not a refusal)"; else pass "$n"; fi; }
rel_files() { srv "sudo ls -A /opt/tando/apps/$1/releases/\$(sudo readlink /opt/tando/apps/$1/current | sed 's,.*/,,')"; }

rm -rf "$E"; mkdir -p "$E/w" || exit 1
# the tando to test: a copy of this checkout, with docs/ci-integration.patch and
# docs/ci-security.patch applied where the core does not carry them yet
T=$E/tree; mkdir -p "$T"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/server" "$ROOT/templates" "$ROOT/VERSION" "$T/" || exit 1
# the Go server programs (tando-gate among them): host setup builds them from the copy's srv/
cp -R "$ROOT/srv" "$ROOT/scripts" "$T/" || exit 1
# a patch counts as in the core when its marker is there
for p in ci-integration:bin/tando:ci_install_gate "ci-security:lib/deploy.sh:tando-gate admin receive"; do
  f=${p#*:}; m=${f#*:}; f=${f%%:*}; p=${p%%:*}
  if grep -q "$m" "$T/$f"; then log "docs/$p.patch: in the core"; continue; fi
  (cd "$T" && patch -s -p1 -f --no-backup-if-mismatch < "$ROOT/docs/$p.patch") > /dev/null ||
    { echo "FAIL 0 docs/$p.patch does not apply to this checkout"; exit 1; }
  log "docs/$p.patch: applied to the copy under test"
done
R=$T/bin/tando
for f in "$T"/bin/tando "$T"/lib/*.sh "$T"/server/tando-agent "$T"/server/tando-gate "$T"/templates/pre-push; do
  [ -f "$f" ] || continue   # (tando-gate is a Go program now: srv/gate)
  bash -n "$f" || { echo "FAIL 0 syntax $f"; exit 1; }
done
if ! docker image inspect tando-ci-runner:test > /dev/null 2>&1; then
  log "building tando-ci-runner:test (ubuntu 24.04, GNU rsync 3.2.7)"
  mkdir -p "$E/runner"
  cat > "$E/runner/Dockerfile" <<'DOCKERFILE'
# Stand-in for a GitHub ubuntu-24.04 runner: GNU rsync 3.2.x, OpenSSH, git, Node + npm.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      rsync openssh-client git ca-certificates nodejs npm bash curl \
 && rm -rf /var/lib/apt/lists/* && useradd -m runner
USER runner
WORKDIR /home/runner
DOCKERFILE
  docker build -q -t tando-ci-runner:test "$E/runner" > /dev/null ||
    { echo "FAIL 0 cannot build tando-ci-runner:test"; exit 1; }
fi
if [ "${1:-}" = --no-reset ]; then :
elif [ "$TN" = tando-test-ci ] || [ "${TANDO_TEST_OWNED:-}" = 1 ]; then
  log "resetting the test server $TN"
  "$ROOT/test/server/up.sh" --reset >&2 || exit 1
else
  log "reusing $TN (not ours to reset): removing alpha, bravo, charlie"
  "$ROOT/test/server/up.sh" >&2 || exit 1
  for a in alpha bravo charlie; do
    srv "sudo test -f /opt/tando/apps/$a/app.conf && sudo /opt/tando/bin/tando-agent destroy $a purge" > /dev/null 2>&1
  done
fi
cd "$E/w" || exit 1
# OpenSSH 9.8+ penalises a source address after a few failed logins (PerSourcePenalties). The
# attack section fails logins on purpose, all from the one Docker gateway address, which would
# then lock out the rest of the run (the admin too). Test server only; see docs/CI.md.
srv "echo 'PerSourcePenalties no' | sudo tee /etc/ssh/sshd_config.d/05-tando-test.conf > /dev/null &&
  sudo sshd -t && sudo systemctl reload ssh" || { echo "could not configure the test sshd"; exit 1; }

# ---- 0. apps: alpha (A: node with an npm build), bravo (B: data dir, env secret), charlie -----
for a in alpha bravo charlie bravo-2; do
  cp -R "$ROOT/examples/hello" "$a"
  conf_set "$a/tando.conf" app "$a"
done
cat > alpha/package.json <<'EOF'
{ "name": "alpha", "version": "1.0.0", "private": true, "scripts": { "build": "node build.js" } }
EOF
cat > alpha/package-lock.json <<'EOF'
{ "name": "alpha", "version": "1.0.0", "lockfileVersion": 3, "requires": true,
  "packages": { "": { "name": "alpha", "version": "1.0.0" } } }
EOF
echo "require('fs').writeFileSync('BUILT', 'built ' + require('fs').readFileSync('VERSION', 'utf8'))" > alpha/build.js
conf_set alpha/tando.conf build "npm run build"
head -c 300000 /dev/urandom > alpha/blob.bin
conf_set bravo/tando.conf data data
# the real user's path: the host key is shown and trusted (--yes) into the config's known_hosts
"$R" host add test vmadmin@127.0.0.1 --port "$SP" --key "$ROOT/test/server/id_test" --yes > "$E/host-add.out" 2>&1 ||
  { cat "$E/host-add.out"; echo "FAIL 0 host add (host key trusted with --yes)"; exit 1; }
check "0c host add trusted the server's host key (no --insecure-test)" eval \
  'grep -q "$(srv "cut -d\" \" -f2 /etc/ssh/ssh_host_ed25519_key.pub")" "$E/cfg/known_hosts" && grep -qx insecure=0 "$E/cfg/hosts/test"'
"$R" host setup test public_port="$HP" > "$E/setup.out" 2>&1 || { cat "$E/setup.out"; exit 1; }
for a in alpha bravo charlie bravo-2; do (cd $a && "$R" up > "$E/up.$a" 2>&1) || { cat "$E/up.$a"; exit 1; }; done
(cd bravo && "$R" env set SECRET_B=bravo-secret-value > /dev/null 2>&1)
(cd alpha && "$R" env set SECRET_A=alpha-secret-value > /dev/null 2>&1)
srv "sudo -u tando-bravo sh -c 'echo bravo-data-value > /opt/tando/apps/bravo/shared/data/db.json'" ||
  srv "sudo install -o tando-bravo -m 600 /dev/null /opt/tando/apps/bravo/shared/data/db.json && echo bravo-data-value | sudo tee /opt/tando/apps/bravo/shared/data/db.json > /dev/null"
check "0a four apps live (alpha v$(ver alpha), bravo v$(ver bravo))" test "$(ver alpha)$(ver bravo)$(ver charlie)$(ver bravo-2)" = 1111
check "0b host setup installed the gate (root 755)" test "$(srv 'stat -c "%U %a" /opt/tando/bin/tando-gate')" = "root 755"

# ---- 1. tando ci setup, ls -----------------------------------------------------------------
log "1. ci setup"
(cd alpha && "$R" ci setup > "$E/setup.alpha" 2> "$E/setup.alpha.err")
check "1a ci setup alpha succeeds" test $? = 0
(cd bravo && "$R" ci setup > "$E/setup.bravo" 2> /dev/null)
(cd charlie && "$R" ci setup > "$E/setup.charlie" 2> /dev/null)
(cd bravo-2 && "$R" ci setup > "$E/setup.bravo-2" 2> /dev/null)
KB2=$E/key.bravo-2; secret "$E/setup.bravo-2" TANDO_DEPLOY_KEY > "$KB2"; chmod 600 "$KB2"
KA=$E/key.alpha KB=$E/key.bravo
secret "$E/setup.alpha" TANDO_DEPLOY_KEY > "$KA"; secret "$E/setup.bravo" TANDO_DEPLOY_KEY > "$KB"; chmod 600 "$KA" "$KB"
check "1b prints the private key and host, port, known_hosts" \
  test "$(grep -c BEGIN "$KA")$(secret "$E/setup.alpha" TANDO_HOST)$(secret "$E/setup.alpha" TANDO_PORT)" \
  = "1127.0.0.1$SP"
check "1c known_hosts line matches the server's host key" \
  test "$(secret "$E/setup.alpha" TANDO_KNOWN_HOSTS | awk '$2 == "ssh-ed25519" { print $3 }')" = \
       "$(srv 'cut -d" " -f2 /etc/ssh/ssh_host_ed25519_key.pub')"
check "1d the server keeps no private key" test -z "$(srv 'sudo grep -rl "PRIVATE KEY" /opt/tando /etc/ssh/sshd_config.d /etc/sudoers.d 2>/dev/null')"
FPA=$(ssh-keygen -lf "$KA" | awk '{print $2}')
(cd alpha && "$R" ci ls > "$E/ls.alpha" 2>&1)
check "1e ci ls shows the key's fingerprint" has "$E/ls.alpha" "${FPA:0:20}"
check "1f one login user per app, shell = gate, home root-owned 711, key file root:tando-keys 640" test \
  "$(srv 'getent passwd tando-d-alpha | cut -d: -f6,7; sudo stat -c "%U %a" /opt/tando/ci/alpha; sudo stat -c "%U:%G %a" /opt/tando/ci/alpha/.ssh/authorized_keys' | tr '\n' ' ')" = \
  "/opt/tando/ci/alpha:/opt/tando/bin/tando-gate root 711 root:tando-keys 640 "
check "1g authorized_keys: restrict + forced command" \
  test "$(srv 'sudo grep -c "^restrict,command=\"/opt/tando/bin/tando-gate key [0-9a-f]*\" ssh-ed25519 " /opt/tando/ci/alpha/.ssh/authorized_keys')" = 1
srv "sudo sudo -l -U tando-d-alpha" > "$E/sudo-l" 2>&1
check "1h sudo: exactly six fixed commands for alpha (the four of a deploy, and preview-up and preview-rm)" test \
  "$(grep -o '/opt/tando/bin/tando-gate root alpha [a-z-]*' "$E/sudo-l" | tr '\n' ' ')" = \
  "/opt/tando/bin/tando-gate root alpha begin /opt/tando/bin/tando-gate root alpha end /opt/tando/bin/tando-gate root alpha activate /opt/tando/bin/tando-gate root alpha receive /opt/tando/bin/tando-gate root alpha preview-up /opt/tando/bin/tando-gate root alpha preview-rm "
check "1i sudo rule names nothing else (no ALL, no wildcard)" sh -c "sed -n '/may run/,\$p' '$E/sudo-l' | grep -Eq '\\*|: *ALL|, *ALL'; test \$? = 1"
srv "sudo sshd -T -C user=tando-d-alpha,host=x,addr=127.0.0.1" > "$E/sshd.d"
srv "sudo sshd -T -C user=vmadmin,host=x,addr=127.0.0.1" > "$E/sshd.a"
check "1j sshd for deploy users: no tty, no forwarding, keys only" test \
  "$(grep -Ec '^(permittty no|disableforwarding yes|allowtcpforwarding no|allowagentforwarding no|permittunnel no|authenticationmethods publickey|permituserrc no)$' "$E/sshd.d")" = 7
check "1k sshd settings do not leak to the admin" has "$E/sshd.a" "^permittty yes"
check "1l incoming/ belongs to the deploy user, mode 700" \
  test "$(srv 'stat -c "%U %a" /opt/tando/apps/alpha/incoming')" = "tando-d-alpha 700"

# ---- 2. deploy with the key (laptop: openrsync) ---------------------------------------------
log "2. deploy with a deploy key"
cd "$E/w/alpha" || exit 1
echo 2 > VERSION
CI=true as_key "$E/setup.alpha" "$R" deploy > "$E/d2.out" 2>&1
check "2a CI deploy with the key: alpha answers v2" test "$(ver alpha)" = 2
# plain: no box, no escape sequence, steps as "[i/n] name ... ok" lines (not tied to a step number)
plain() { ! grep -q $'[│╭╰\e]' "$1" && grep -Eq '^\[[0-9]+/[0-9]+\] +upload +ok' "$1"; }
check "2b CI output is plain, one line per step" plain "$E/d2.out"
echo 2 > VERSION
(CI=true as_key "$E/setup.alpha" "$R" deploy | head -1 > /dev/null) 2> "$E/pipe.err"
check "2b2 plain output into a reader that stops early prints no broken-pipe error" hasnt "$E/pipe.err" "cmd-ci.sh.*Broken pipe"
check "2c the build ran (BUILT shipped)" test "$(srv 'sudo cat /opt/tando/apps/alpha/current/BUILT')" = "built 2"
echo 3 > VERSION
as_key "$E/setup.alpha" "$ROOT/test/pty-run.sh" "$E/d3.tty" "$R" deploy < /dev/null > /dev/null 2>&1
check "2d on a terminal the key shows the same boxed progress" sh -c "grep -q '╭─ deploy alpha' '$E/d3.tty' && grep -q 'upload' '$E/d3.tty'"
check "2e alpha answers v3" test "$(ver alpha)" = 3
echo 4 > VERSION
CI=true as_key "$E/setup.alpha" "$R" deploy > "$E/d4.out" 2>&1
up4=$(sed -n 's/.*upload  *ok .* \([0-9]*\) files changed, \(.*\) sent/\1 \2/p' "$E/d4.out")
check "2f openrsync through the gate sends deltas only ($up4)" sh -c "echo '$up4' | grep -Eq '^[1-3] [0-9.]+ (B|KB)$'"
echo 5 > VERSION
"$R" deploy > "$E/d5.out" 2>&1
check "2g the admin still deploys (uploads as tando-d-alpha): v5" test "$(ver alpha)" = 5
check "2h ... and incoming/ stays tando-d-alpha, 700" \
  test "$(srv 'stat -c "%U %a" /opt/tando/apps/alpha/incoming; sudo find /opt/tando/apps/alpha/incoming ! -user tando-d-alpha | wc -l' | tr '\n' ' ')" = "tando-d-alpha 700 0 "
CI=true as_key "$E/setup.alpha" "$R" status > "$E/st.out" 2>&1
check "2i status with the key shows alpha" has "$E/st.out" "alpha"
check "2j ... and nothing of bravo or charlie" hasnt "$E/st.out" "bravo\|charlie"
CI=true as_key "$E/setup.alpha" "$R" releases > "$E/rel.out" 2>&1
check "2k releases with the key" has "$E/rel.out" "verified"
CI=true as_key "$E/setup.alpha" "$R" history > "$E/hist.out" 2>&1
check "2l history with the key: alpha's deploys only" sh -c "grep -q deploy '$E/hist.out' && ! grep -q 'bravo\|charlie' '$E/hist.out'"
(cd "$E/w/alpha" && "$R" ci ls > "$E/ls2" 2>&1)
check "2m ci ls shows the last deploy" sh -c "! grep -q never '$E/ls2'"

# a failing release: the CI output names the phase, the reason and the HTTP status, and holds
# no application log line (the app prints CUSTOMER-DATA-LINE at start)
"$R" env set UNHEALTHY_VERSION=6-CUSTOMER-DATA-LINE > /dev/null 2>&1
echo 6-CUSTOMER-DATA-LINE > VERSION
CI=true as_key "$E/setup.alpha" "$R" deploy > "$E/d6.out" 2>&1
rc6=$?
check "2n failed CI deploy exits non-zero" test $rc6 != 0
check "2o ... names the phase and reason with the HTTP status" sh -c "grep -q 'preflight fail' '$E/d6.out' && grep -q 'HTTP 500' '$E/d6.out'"
check "2p ... prints no application log line" hasnt "$E/d6.out" "CUSTOMER-DATA-LINE on"
ID6=$(sed -n 's/^release \([0-9-]*\)$/\1/p' "$E/d6.out")
check "2q (the server has that log line: the admin sees it)" sh -c "'$SSH' 'sudo $AG deploy-status alpha $ID6' | grep -q 'log=.*CUSTOMER-DATA-LINE on'"
check "2r the running app was not touched (v5)" test "$(ver alpha)" = 5
"$R" env unset UNHEALTHY_VERSION > /dev/null 2>&1

# GNU rsync 3.2.7 (GitHub's ubuntu-24.04) as the client, in a Linux container on the server's network
log "2. GNU rsync client"
mkdir -p "$E/gnu" && cp -R "$E/w/alpha" "$E/gnu/app" && rm -rf "${E:?}/gnu/app/.tando"
echo 7 > "$E/gnu/app/VERSION"
gnu() { # script: runs as user runner in tando-ci-runner:test, ssh to 127.0.0.1:22 of the server
  # the key and known_hosts are mounted files: never on a command line (ps)
  mkdir -p "$E/gnu/secrets"; cp "$KA" "$E/gnu/secrets/key"
  secret "$E/setup.alpha" TANDO_KNOWN_HOSTS > "$E/gnu/secrets/known_hosts"
  docker run --rm ${TANDO_TEST_RUN:+--label "tando.run=$TANDO_TEST_RUN"} --network "container:$TN" -v "$T:/tando:ro" -v "$E/gnu:/gnu" \
    -e TANDO_DEPLOY_KEY=/gnu/secrets/key -e TANDO_HOST=127.0.0.1 -e TANDO_PORT=22 -e CI=true \
    -e TANDO_COLOR=never tando-ci-runner:test bash -c \
    "export HOME=/tmp/h TANDO_KNOWN_HOSTS=\"\$(cat /gnu/secrets/known_hosts)\"; mkdir -p \$HOME; cd /gnu/app; $1"
}
gnu '/tando/bin/tando deploy' > "$E/g7.out" 2>&1
check "2s GNU rsync 3.2.7 client through the gate: alpha answers v7" test "$(ver alpha)" = 7
echo 8 > "$E/gnu/app/VERSION"
gnu 'rsync --version | head -1; /tando/bin/tando deploy' > "$E/g8.out" 2>&1
up8=$(sed -n 's/.*upload  *ok .* \([0-9]*\) files changed, \(.*\) sent/\1 \2/p' "$E/g8.out")
check "2t GNU rsync sends deltas only ($up8; blob.bin is 300 KB)" sh -c "echo '$up8' | grep -Eq '^[1-3] [0-9.]+ (B|KB)$' && grep -q 'version 3.2.7' '$E/g8.out'"
check "2u alpha answers v8" test "$(ver alpha)" = 8

# ---- 3. what a deploy key cannot do (its own app) -----------------------------------------
log "3. forbidden verbs"
for v in "configure alpha" "env-set alpha" "env-ls alpha" "env-unset alpha" "rollback alpha" \
    "rollback alpha 20260101-000000" "start alpha" "stop alpha" "restart alpha" "destroy alpha" \
    "unlock alpha" "logs alpha" "jobs alpha" "backup-run alpha manual" "backup-ls alpha" \
    "backup-cat alpha x" "db-url alpha" "exec-app alpha" "run-job alpha x" "recover alpha" \
    "run-activation alpha 20260101-000000 0 0" "setup" "doctor 1" "recover-all"; do
  refused_by "3 key cannot run '$v'" "tando-gate: not allowed with a deploy key" ka "sudo -n $AG $v"
  refused_by "3 key cannot run '$v' without sudo" "tando-gate: not allowed with a deploy key" ka "$AG $v"
done
ka "sudo -n $AG env-ls alpha" > "$E/envls" 2>&1
check "3a env values never reach the key" hasnt "$E/envls" "alpha-secret-value"
(cd "$E/w/alpha" && CI=true as_key "$E/setup.alpha" "$R" up > "$E/up.key" 2>&1)
check "3b tando up (configuration) with the key is refused" sh -c "grep -q 'not allowed with a deploy key: configure' '$E/up.key'"
(cd "$E/w/alpha" && CI=true as_key "$E/setup.alpha" "$R" rollback > /dev/null 2>&1)
check "3c tando rollback with the key is refused" test $? != 0
(cd "$E/w/alpha" && CI=true as_key "$E/setup.alpha" "$R" ci setup > /dev/null 2>&1)
check "3d tando ci setup with the key is refused" test $? != 0

# ---- 4. no shell, no forwarding, no tty ---------------------------------------------------------
log "4. ssh restrictions"
refused "4a no shell (no command)" ka < /dev/null
refused "4b no shell: bash" ka bash -c id
refused "4c no command: id" ka id
refused "4d no pty: ssh -t" kssh "$KA" tando-d-alpha -tt id
refused "4e no sftp subsystem" kssh "$KA" tando-d-alpha -s sftp < /dev/null
echo x > "$E/scp.txt"
refused "4f no scp" scp -F /dev/null -P "$SP" -i "$KA" -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "$E/scp.txt" tando-d-alpha@127.0.0.1:/tmp/x
refused "4g no stdio forwarding (-W) to the app port" sh -c "echo | ssh ${KOPTS[*]} -i '$KA' -W 127.0.0.1:4100 tando-d-alpha@127.0.0.1 | grep -q ."
ssh "${KOPTS[@]}" -i "$KA" -N -o ExitOnForwardFailure=yes -L 18399:127.0.0.1:4100 tando-d-alpha@127.0.0.1 > /dev/null 2>&1 &
fpid=$!
t_until 10 eval '! kill -0 $fpid 2> /dev/null || (exec 3<> /dev/tcp/127.0.0.1/18399) 2> /dev/null'   # gave up, or listening
refused "4h no local port forwarding (-L)" curl -s -m 2 http://127.0.0.1:18399/
kill $fpid 2> /dev/null; wait $fpid 2> /dev/null
ssh "${KOPTS[@]}" -i "$KA" -N -o ExitOnForwardFailure=yes -R 18398:127.0.0.1:22 tando-d-alpha@127.0.0.1 > /dev/null 2>&1 &
fpid=$!
t_until 10 eval '! kill -0 $fpid 2> /dev/null || srv "ss -ltn | grep -q 18398"'   # refused (ssh exits), or listening
check "4i no remote port forwarding (-R)" srv_no "curl -s -m 2 http://127.0.0.1:18398/ ; ss -ltn | grep -q 18398"
kill $fpid 2> /dev/null; wait $fpid 2> /dev/null
# agent forwarding: a private agent is offered (-o ForwardAgent=<socket>) while a session stays
# open; sshd makes a socket for the session's user only when it accepts (OpenSSH before 10.1 in
# /tmp/ssh-*/, later under ~/.ssh/agent/). The admin's session is the control: it must get one, or
# the probe is broken. AOPTS has no IdentityAgent=none: that turns forwarding off in the client (the
# old check never asked for it). The agent socket path must stay short (unix sockets: 104 bytes).
AD=$(mktemp -d /tmp/tando-ag.XXXXXX)
ssh-agent -D -a "$AD/s" > /dev/null 2>&1 & apid=$!
t_until 10 test -S "$AD/s"
AOPTS=(-F /dev/null -p "$SP" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no
       -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
agent_socks() { srv "sudo find /tmp /var/tmp /home /opt -type s -user $1 2> /dev/null | wc -l" | tr -d ' '; }
fwd_session() { # user key cmd: a session with agent forwarding, kept open for 8 s in the background
  # (the agent by SSH_AUTH_SOCK: OpenSSH 9.6 on Linux does not ask for forwarding with ForwardAgent=<path>)
  sleep 8 | SSH_AUTH_SOCK="$AD/s" ssh "${AOPTS[@]}" -i "$2" -o ForwardAgent=yes -v "$1@127.0.0.1" "$3" > /dev/null 2> "$E/agentfwd.$1" &
}
fwd_session vmadmin "$ROOT/test/server/id_test" 'sleep 6'
t_until 6 eval '[ "$(agent_socks vmadmin)" -ge 1 ]'
check "4j0 (control: the admin's forwarded agent appears on the server)" eval '[ "$(agent_socks vmadmin)" -ge 1 ]'
TOK=$(begin_a)   # with a lease, the gate's rsync server stays up while the client sends nothing
fwd_session tando-d-alpha "$KA" "rsync --server -ltpr . $INC"
t_until 6 eval 'grep -q "Requesting .*agent forwarding" "$E/agentfwd.tando-d-alpha" &&
  srv "pgrep -u tando-d-alpha rsync > /dev/null"'
check "4j no agent forwarding for a deploy key (asked for, session open, no socket on the server: $(agent_socks tando-d-alpha))" \
  eval 'grep -q "Requesting .*agent forwarding" "$E/agentfwd.tando-d-alpha" &&
   srv "pgrep -u tando-d-alpha rsync > /dev/null" && [ "$(agent_socks tando-d-alpha)" = 0 ]'
wait_jobs=$(jobs -p | grep -vx "$apid"); kill $apid 2> /dev/null; for j in $wait_jobs; do wait "$j" 2> /dev/null; done
end_a "$TOK"; rm -rf "${AD:?}"
srv "printf 'touch /tmp/pwned-bashenv\n' > /tmp/evil-env; chmod 644 /tmp/evil-env; rm -f /tmp/pwned-bashenv"
ssh "${KOPTS[@]}" -i "$KA" -o SetEnv=BASH_ENV=/tmp/evil-env -o SetEnv=ENV=/tmp/evil-env -o SetEnv=LC_EVIL=x \
  -o SetEnv=LD_PRELOAD=/tmp/x.so tando-d-alpha@127.0.0.1 "$AG info" > /dev/null 2>&1
ssh "${KOPTS[@]}" -i "$KA" -o SetEnv=BASH_ENV=/tmp/evil-env tando-d-alpha@127.0.0.1 "rsync --server -ltpr . $INC" < /dev/null > /dev/null 2>&1
check "4k BASH_ENV/ENV/LD_PRELOAD sent by the client run nothing" test "$(srv 'ls /tmp/pwned-bashenv 2>/dev/null | wc -l')" = 0
denied_as root "4l the login shell is the gate: su -c id refused" su -s /opt/tando/bin/tando-gate tando-d-alpha -c id
denied_as root "4m the gate as a shell refuses a forged forced command without SSH_ORIGINAL_COMMAND" su tando-d-alpha -c "'/opt/tando/bin/tando-gate key 000000000000'"

# ---- 5. revoke and rotate ---------------------------------------------------------------------
log "5. revoke, rotate"
(cd "$E/w/charlie" && "$R" ci setup > "$E/setup.charlie2" 2> /dev/null)
KC1=$E/key.c1 KC2=$E/key.c2
secret "$E/setup.charlie" TANDO_DEPLOY_KEY > "$KC1"; secret "$E/setup.charlie2" TANDO_DEPLOY_KEY > "$KC2"; chmod 600 "$KC1" "$KC2"
check "5a two keys for charlie both work" test "$(kssh "$KC1" tando-d-charlie "$AG info" | grep -c arch)$(kssh "$KC2" tando-d-charlie "$AG info" | grep -c arch)" = 11
FPC1=$(ssh-keygen -lf "$KC1" | awk '{print $2}')
kssh "$KC1" tando-d-charlie -o ServerAliveInterval=1 "rsync --server -ltprcze.iLsfxCIvu . /opt/tando/apps/charlie/incoming/" > /dev/null 2>&1 &
(cd "$E/w/charlie" && "$R" ci revoke "$FPC1" > "$E/rev.out" 2>&1)
check "5b revoke by fingerprint" has "$E/rev.out" "revoked 1 key"
refused "5c the revoked key no longer logs in" kssh "$KC1" tando-d-charlie "$AG info"
check "5d the other key still works" test "$(kssh "$KC2" tando-d-charlie "$AG info" | grep -c arch)" = 1
(cd "$E/w/charlie" && "$R" ci rotate > "$E/setup.charlie3" 2> /dev/null)
KC3=$E/key.c3; secret "$E/setup.charlie3" TANDO_DEPLOY_KEY > "$KC3"; chmod 600 "$KC3"
refused "5e after rotate the old key fails" kssh "$KC2" tando-d-charlie "$AG info"
(cd "$E/w/charlie" && echo 2 > VERSION && CI=true TANDO_KEYFILE=$KC3 as_key "$E/setup.charlie3" "$R" deploy > "$E/c2.out" 2>&1)
check "5f after rotate the new key deploys (key given as a file path)" test "$(ver charlie)" = 2
(cd "$E/w/charlie" && "$R" ci revoke all > /dev/null 2>&1)
refused "5g revoke all: the rotated key fails too" kssh "$KC3" tando-d-charlie "$AG info"
CUID=$(srv 'id -u tando-d-charlie')
(cd "$E/w/charlie" && echo charlie | "$R" destroy > "$E/destroy.out" 2>&1)
check "5h destroy removes the deploy user, its sudo rule and home" \
  test "$(srv 'getent passwd tando-d-charlie; ls /etc/sudoers.d/tando-d-charlie /opt/tando/ci/charlie 2>/dev/null' | wc -l | tr -d ' ')" = 0
check "5i the removed deploy user's uid ($CUID) is retired" srv "grep -qx '$CUID' /opt/tando/retired-uids"
(cd "$E/w/charlie" && "$R" up > /dev/null 2>&1 && "$R" ci setup > "$E/setup.charlie4" 2> /dev/null)
check "5j a new deploy user of charlie gets another uid" sh -c "u=\$('$SSH' 'id -u tando-d-charlie'); test -n \"\$u\" && test \"\$u\" != '$CUID'"
(cd "$E/w/charlie" && echo charlie | "$R" destroy > /dev/null 2>&1)

# ---- 6. attacks with alpha's key: on bravo, on root, on the release ---------------------------
log "6. attacks"
# 6.1 other apps through the verbs (the app argument must be the caller's own)
for v in "begin bravo x" "end bravo 00000000-0000-0000-0000-000000000000" \
    "activate bravo 00000000-0000-0000-0000-000000000000 1 1" "deploy-status bravo 20260101-000000" \
    "status bravo" "releases bravo" "history bravo" "status" "history" "env-ls bravo" "rollback bravo"; do
  refused_by "6.1 key A: '$v'" "tando-gate: (this key deploys alpha only|not allowed|bad request)" ka "sudo -n $AG $v"
done
ka "$AG status" > "$E/st.all" 2>&1
check "6.1 key A: status without an app shows nothing of bravo" hasnt "$E/st.all" "bravo"
refused_by "6.1 key A cannot log in as bravo's deploy user" "Permission denied" kssh "$KA" tando-d-bravo "$AG info"
refused_by "6.1 key A cannot log in as the admin" "Permission denied" kssh "$KA" vmadmin true
refused_by "6.1 key A cannot log in as root" "Permission denied" kssh "$KA" root true
# 6.2 rsync: paths, directions, options
TOK=$(begin_a)
check "6.2 (key A holds alpha's upload lease)" test -n "$TOK"
mkdir -p "$E/up/x" && echo pwned > "$E/up/x/VERSION"
# shellcheck disable=SC2088  # a literal ~ is the attack
for d in /opt/tando/apps/bravo/incoming/ "$INC../../bravo/incoming/" "${INC}sub/" /opt/tando/apps/alpha/ /tmp/ \
    "$INC/../incoming/" "/opt/tando/apps/alpha/incoming//" '~/' "."; do
  refused "6.2 rsync to '$d'" krsync "$KA" -rlptz "$E/up/x/" "tando-d-alpha@127.0.0.1:$d"
  refused_by "6.2 raw rsync request to '$d'" "tando-gate: (rsync: (a deploy key uploads to|bad arguments)|unexpected characters)" ka "rsync --server -ltprz . $d" < /dev/null
done
check "6.2 nothing landed in bravo's incoming" test "$(srv 'sudo ls -A /opt/tando/apps/bravo/incoming | grep -c pwned; sudo grep -rl pwned /opt/tando/apps/bravo 2>/dev/null | wc -l' | tr '\n' ' ')" = "0 0 "
refused_by "6.2 rsync download of bravo's env (--sender)" "tando-gate: rsync: option not allowed: --sender" krsync "$KA" -rlptz tando-d-alpha@127.0.0.1:/opt/tando/apps/bravo/env "$E/up/stolen"
refused_by "6.2 rsync download of alpha's own incoming" "tando-gate: rsync: option not allowed: --sender" krsync "$KA" -rlptz "tando-d-alpha@127.0.0.1:$INC" "$E/up/stolen2/"
# options as the server would receive them (the attacker controls the client entirely)
for o in -H -D --devices --specials -o -g -ltprHe.iLsfxCIvu -ltprDze.iLsf -logDtpre.iLsfxCIvu \
    --log-file=/tmp/x --log-file-format=%f "--temp-dir=/tmp" "--backup-dir=/tmp" -b --backup \
    "--link-dest=/opt/tando/apps/bravo/incoming" "--copy-dest=/opt/tando/apps/bravo/incoming" \
    "--compare-dest=/opt/tando/apps/bravo/env" "--partial-dir=/tmp/p" --partial --remove-source-files \
    -K --keep-dirlinks -L --copy-links --copy-unsafe-links --max-delete=0 --chmod=u+s --suffix=x \
    --write-devices --inplace --append -x --fake-super --files-from=/etc/passwd --from0 \
    --super --omit-dir-times --no-implied-dirs --munge-links --safe-links=no --sender --daemon \
    --config=/tmp/c --address=0.0.0.0 --port=873 --iconv=x --checksum-seed=1 --out-format=%f \
    --timeout=0 --bwlimit=1 --mkpath --remote-option=--sender --rsh=sh -e -E -X -A -U -N -S \
    -W -R -u -y -m -i -k -s -T -f -F -C -B; do
  refused_by "6.2 server option $o" "tando-gate: (rsync: (option not allowed|bad arguments)|unexpected characters)" ka "rsync --server -ltprz $o . $INC" < /dev/null
done
refused_by "6.2 server option --usermap=*:root (odd characters)" "tando-gate: unexpected characters" ka "rsync --server -ltprz --usermap=*:root . $INC" < /dev/null
# options through the real client, where they reach the server
for o in -H -D -o -g "--link-dest=/opt/tando/apps/bravo/incoming" "--copy-dest=/opt/tando/apps/bravo/incoming" \
    "--compare-dest=/opt/tando/apps/bravo/env" "--temp-dir=/tmp" "--partial-dir=/tmp/p" "--backup-dir=/tmp" -b; do
  refused_by "6.2 client rsync $o" "tando-gate: rsync: option not allowed" krsync "$KA" -rlptz "$o" "$E/up/x/" "tando-d-alpha@127.0.0.1:$INC"
done
for p in "rsync --server --sender -vlogDtpre.iLsfxC . /opt/tando/apps/bravo/env" "sh -c id" \
    "rsync --server --log-file=/tmp/l -ltprcze.iLsfxCIvu . $INC" "/bin/rsync --server -ltpr . $INC" \
    "rsync --server -ltpr . $INC extra" "rsync --server -ltpr $INC" "rsync --daemon --server ."; do
  refused_by "6.2 --rsync-path='$p'" "tando-gate: " krsync "$KA" -rlptz --rsync-path="$p" "$E/up/x/" "tando-d-alpha@127.0.0.1:$INC"
done
for c in "rsync --server -ltpre.iLsfxCIvu --config=/x . $INC" "rsync --server -ltpr -e.LsfxC . $INC" \
    "rsync --server -ltprDe.iLsfxCIvu . $INC" "rsync --server -ltpre.iLs/f . $INC" "rsync --server -ltpr .. $INC" \
    "rsync --server -ltpr . . $INC" "rsync --server" "rsync"; do
  refused_by "6.2 raw request '$c'" "tando-gate: " ka "$c" < /dev/null
done
# 6.3 argument injection and odd tokens
for c in "sudo -n $AG begin alpha \$(id)" "sudo -n $AG begin alpha;id" "sudo -n $AG begin alpha|id" \
    "sudo -n $AG begin alpha \`id\`" "sudo -n $AG deploy-status alpha ../../bravo" \
    "sudo -n $AG deploy-status alpha 20260101-000000 extra" "sudo -n $AG activate alpha $TOK 1 1 --x" \
    "sudo -n $AG activate alpha $TOK 1e9 1" "sudo -n $AG activate alpha ../../../etc 1 1" \
    "sudo -n $AG end alpha *" "sudo -n $AG history alpha 99999" "sudo -n $AG history alpha -1" \
    "sudo -n $AG status alpha extra" "sudo -n -u root $AG status alpha" "sudo -s" "sudo -n /bin/sh" \
    "sudo -n /opt/tando/bin/tando-gate root bravo begin" "sudo -n /opt/tando/bin/tando-gate admin install" \
    "sudo -n $AG begin ALPHA x" "sudo -n $AG begin alpha x"$'\n'"id" "$AG begin alpha x"$'\t'"x" \
    "$(printf 'sudo -n %s status alpha %0400d' "$AG" 0)" "sudo -n $AG status $(printf 'a%.0s' $(seq 40))" \
    "$(printf 'sudo -n %s status \303\251' "$AG")" "sudo -n $AG status alpha"$'\001'; do
  refused_by "6.3 request '$(printf '%s' "$c" | tr '\n\t\001' '???' | cut -c1-70)'" "tando-gate: " ka "$c" < /dev/null
done
end_a "$TOK"   # the lease taken in 6.2
check "6.3 refusals are in the journal (auth, tando-gate)" sh -c "'$SSH' 'sudo journalctl -t tando-gate --no-pager' | grep -q 'tando-d-alpha key [0-9a-f]* refused: unexpected characters'"
check "6.3 (no injected command ran: no file in /tmp from id)" test "$(srv 'ls /tmp | grep -c pwn')" = 0
# 6.4 OS boundary: as if the key holder had code execution as tando-d-alpha
denied_as tando-d-alpha "6.4 tando-d-alpha cannot read alpha's env" cat /opt/tando/apps/alpha/env
denied_as tando-d-alpha "6.4 tando-d-alpha cannot read bravo's env" cat /opt/tando/apps/bravo/env
denied_as tando-d-alpha "6.4 tando-d-alpha cannot read bravo's shared data" cat /opt/tando/apps/bravo/shared/data/db.json
denied_as tando-d-alpha "6.4 tando-d-alpha cannot read alpha's shared data" ls /opt/tando/apps/alpha/shared
denied_as tando-d-alpha "6.4 tando-d-alpha cannot list bravo's incoming" ls /opt/tando/apps/bravo/incoming
denied_as tando-d-alpha "6.4 tando-d-alpha cannot write bravo's incoming" touch /opt/tando/apps/bravo/incoming/pwned
denied_as tando-d-alpha "6.4 tando-d-alpha cannot read a release" cat /opt/tando/apps/bravo/current/server.js
denied_as tando-d-alpha "6.4 tando-d-alpha cannot change its authorized_keys" sh -c "'echo x >> /opt/tando/ci/alpha/.ssh/authorized_keys'"
denied_as tando-d-alpha "6.4 tando-d-alpha cannot write its home" touch /opt/tando/ci/alpha/x
denied_as tando-d-alpha "6.4 tando-d-alpha cannot read the key list" cat /opt/tando/ci/alpha/keys
denied_as tando-d-alpha "6.4 tando-d-alpha cannot read its authorized_keys (key ids)" cat /opt/tando/ci/alpha/.ssh/authorized_keys
denied_as tando-d-alpha "6.4 sudo: root mode for bravo" sudo -n /opt/tando/bin/tando-gate root bravo begin
denied_as tando-d-alpha "6.4 sudo: an extra argument" sudo -n /opt/tando/bin/tando-gate root alpha begin x
denied_as tando-d-alpha "6.4 sudo: the agent directly" sudo -n /opt/tando/bin/tando-agent status
denied_as tando-d-alpha "6.4 sudo: admin mode" sudo -n /opt/tando/bin/tando-gate admin install
denied_as tando-d-alpha "6.4 sudo: a shell" sudo -n /bin/sh -c id
KIDB=$(srv "sudo cut -f1 /opt/tando/ci/bravo/keys")
check "6.4 root mode with bravo's key id from alpha's user" srv_no "printf 'keyid=$KIDB\n' | sudo -u tando-d-alpha sudo -n /opt/tando/bin/tando-gate root alpha begin"
check "6.4 root mode called by the admin is not a deploy user" srv_no "printf 'keyid=$KIDB\n' | sudo /opt/tando/bin/tando-gate root bravo begin"
check "6.4 a stray parameter on stdin" srv_no "printf 'keyid=$KIDB\ncmd=id\n' | sudo -u tando-d-bravo sudo -n /opt/tando/bin/tando-gate root bravo begin"
# 6.5 hostile uploads: each activation must be refused and alpha keep serving v8
up_attack() { # name reason-regex; $E/up/a is the upload; as the CI client would: begin, rsync, activate
  local n=$1 re=$2 tok id
  tok=$(begin_a)
  [ -n "$tok" ] || { fail "$n (no upload lease)"; return; }
  if ! krsync "$KA" -rlptz -c --delete "$E/up/a/" "tando-d-alpha@127.0.0.1:$INC" > "$E/out" 2>&1; then
    end_a "$tok"; pass "$n (upload refused: $(tail -1 "$E/out" | cut -c1-60))"; return
  fi
  [ -n "${PREP:-}" ] && srv "$PREP"
  id=$(ka "sudo -n $AG activate alpha $tok 0 0" 2> "$E/act.err" | sed -n 's/^id=//p')
  if [ -z "$id" ]; then
    if grep -Eq -- "$re" "$E/act.err"; then pass "$n (refused: $(tail -1 "$E/act.err" | cut -c1-70))"
    else fail "$n (refused for another reason: $(tail -1 "$E/act.err" | cut -c1-70))"; fi
    return
  fi
  local r=""; for _ in $(seq 1 40); do
    r=$(ka "$AG deploy-status alpha $id" | sed -n 's/^result=//p')
    case $r in running|"") sleep 0.5;; *) break;; esac
  done
  ka "$AG deploy-status alpha $id" | sed -n 's/^message=//p' > "$E/act.msg"
  if [ "$r" = ok ] || [ "$r" = verified ]; then
    # the receiver removed the escaping link on arrival: the release must hold none
    if [ "$(srv "sudo find /opt/tando/apps/alpha/releases/$id -type l -exec readlink -f {} \\; | grep -vc '^/opt/tando/apps/alpha/releases/$id/'")" = 0 ]; then
      pass "$n (link removed on arrival; the release has no link out)"
    else fail "$n (a link out reached release $id)"; fi
    return
  fi
  if [ "$r" = failed ] && [ "$(ver alpha)" = 8 ] && grep -Eq -- "$re" "$E/act.msg"; then pass "$n (release failed: $(cut -c1-60 "$E/act.msg"))"
  else fail "$n (result $r, alpha v$(ver alpha): $(cut -c1-60 "$E/act.msg"))"; fi
}
fresh() { rm -rf "${E:?}/up/a"; cp -R "$E/gnu/app/.tando/stage" "$E/up/a" 2> /dev/null || cp -R "$E/w/alpha" "$E/up/a"; echo 8 > "$E/up/a/VERSION"; }
fresh; ln -s /etc/shadow "$E/up/a/shadow"; PREP="" up_attack "6.5 absolute symlink to /etc/shadow" "absolute symlink"
fresh; ln -s ../../bravo/env "$E/up/a/benv"; PREP="" up_attack "6.5 relative symlink to bravo's env" "symlink leaves the (release|upload)"
fresh; ln -s ../../../../../../opt/tando/apps/bravo/shared "$E/up/a/bdata"; PREP="" up_attack "6.5 relative symlink to bravo's shared data" "symlink leaves the (release|upload)"
fresh; mkdir -p "$E/up/a/d"; ln -s /opt/tando/apps/bravo/incoming "$E/up/a/d/l"; PREP="" up_attack "6.5 symlinked directory into bravo's incoming" "absolute symlink"
# setuid/setgid: the gate strips them after the upload; if one slipped through (simulated by
# setting it on the server), the activation refuses it
fresh; echo x > "$E/up/a/suid"; chmod 4755 "$E/up/a/suid"; echo x > "$E/up/a/sgid"; chmod 2755 "$E/up/a/sgid"
TOK=$(begin_a); krsync "$KA" -rlptz -c --delete "$E/up/a/" "tando-d-alpha@127.0.0.1:$INC" > /dev/null 2>&1
check "6.5 setuid/setgid bits sent by the client are stripped on arrival" \
  test "$(srv "sudo find $INC -perm /6000 | wc -l")" = 0
end_a "$TOK"
fresh; echo x > "$E/up/a/suid"; PREP="sudo -u tando-d-alpha chmod 4755 $INC/suid" up_attack "6.5 setuid file (set after the upload)" "setuid"
fresh; echo x > "$E/up/a/sgid"; PREP="sudo -u tando-d-alpha chmod 2755 $INC/sgid" up_attack "6.5 setgid file (set after the upload)" "setuid/setgid"
fresh; echo SECRET=1 > "$E/up/a/.env.production"; PREP="" up_attack "6.5 .env file" "secret file in release"
fresh; PREP="sudo -u tando-d-alpha ln $INC/server.js $INC/hl.js" up_attack "6.5 hardlink inside the upload" "hardlink in the upload"
fresh; PREP="sudo -u tando-d-alpha mkfifo $INC/fifo" up_attack "6.5 fifo in the upload" "special file"
fresh; PREP="sudo mknod $INC/null c 1 3" up_attack "6.5 device node in the upload" "special file|foreign owner"
fresh; PREP="sudo touch $INC/rootfile" up_attack "6.5 file not owned by the uploader" "foreign owner"
# write through a symlinked directory: first upload a link to bravo's incoming, then a file under it
TOK=$(begin_a); rm -rf "${E:?}/up/l1" "${E:?}/up/l2"; mkdir -p "$E/up/l1/d" "$E/up/l2/d/l"
ln -s /opt/tando/apps/bravo/incoming "$E/up/l1/d/l"; echo pwned > "$E/up/l2/d/l/pwned"
krsync "$KA" -rlpt "$E/up/l1/" "tando-d-alpha@127.0.0.1:$INC" > /dev/null 2>&1
krsync "$KA" -rlpt --keep-dirlinks "$E/up/l2/" "tando-d-alpha@127.0.0.1:$INC" > /dev/null 2>&1
krsync "$KA" -rlpt "$E/up/l2/" "tando-d-alpha@127.0.0.1:$INC" > /dev/null 2>&1
check "6.5 a file sent under a symlinked directory never reaches bravo" test "$(srv 'sudo ls /opt/tando/apps/bravo/incoming | grep -c pwned')" = 0
srv "sudo rm -rf $INC/d"; end_a "$TOK"
denied_as tando-d-alpha "6.5 a hardlink to another user's file is refused by the kernel" ln /opt/tando/apps/bravo/app.conf "$INC/conf"
check "6.5 nothing was written into bravo's incoming through a link" test "$(srv 'sudo find /opt/tando/apps/bravo/incoming -newer /opt/tando/ci/alpha/keys | wc -l')" = 0
srv "sudo rm -f $INC/null $INC/rootfile $INC/fifo $INC/hl.js; sudo rm -rf /tmp/pwn*" > /dev/null 2>&1
check "6.5 alpha still answers v8" test "$(ver alpha)" = 8
# 6.6 a second session swaps files while the first activates
rm -rf "${E:?}/up/a" "${E:?}/up/b"; cp -R "$E/w/alpha" "$E/up/a"; rm -rf "${E:?}/up/a/.tando"; echo 9 > "$E/up/a/VERSION"
mkdir -p "$E/up/b"; head -c 1500000 /dev/urandom > "$E/up/b/0big.bin"; echo PWNED > "$E/up/b/VERSION"
TOK=$(begin_a)
krsync "$KA" -rlptz -c --delete "$E/up/a/" "tando-d-alpha@127.0.0.1:$INC" > /dev/null 2>&1
# slow link for session 2 (a relay with a rate limit; --bwlimit would be refused by the gate)
cat > "$E/throttle.pl" <<'PL'
use IO::Socket::INET; use IO::Select;
my ($h, $p, $rate) = @ARGV;
my $s = IO::Socket::INET->new(PeerAddr => $h, PeerPort => $p) or die "connect: $!";
binmode STDIN; binmode STDOUT; $| = 1;
my $sel = IO::Select->new(\*STDIN, $s);
while (my @r = $sel->can_read) {
  for my $fh (@r) {
    my $n = sysread($fh, my $buf, 4096); exit 0 unless $n;
    if ($fh == $s) { syswrite(STDOUT, $buf) } else { syswrite($s, $buf); select(undef, undef, undef, $n / $rate) }
  }
}
PL
rsync -e "ssh ${KOPTS[*]} -i $KA -o ProxyCommand='perl $E/throttle.pl 127.0.0.1 $SP 40000'" -rlpt \
  "$E/up/b/" "tando-d-alpha@127.0.0.1:$INC" > "$E/swap.out" 2>&1 &
spid=$!
in_flight() { [ "$(srv "sudo ls -A $INC | grep -c 0big")" -ge 1 ]; }   # the throttled upload has begun
t_until 20 in_flight
check "6.6 (session 2 is mid-transfer when the activation is asked for)" \
  test "$(srv "sudo ls -A $INC | grep -c '0big'")" -ge 1
ID=$(ka "sudo -n $AG activate alpha $TOK 0 0" 2> "$E/act.err" | sed -n 's/^id=//p')
refused_by "6.6 a second activation of the same upload" "tando-gate: .*(already being activated|expired or was taken over|no longer holds .* upload lease)" ka "sudo -n $AG activate alpha $TOK 0 0"
refused_by "6.6 a new rsync during the activation" "tando-gate: rsync: (this upload is being activated|no upload lease)" ka "rsync --server -ltprz . $INC" < /dev/null
wait $spid; src=$?
check "6.6 the slow session was ended when the activation began (rsync rc $src)" sh -c "test $src != 0 && ! grep -q tando-gate '$E/swap.out'"
for _ in $(seq 1 40); do
  r=$(ka "$AG deploy-status alpha $ID" | sed -n 's/^result=//p'); [ "$r" = running ] || break; sleep 0.5
done
check "6.6 the activation succeeded with the first upload: v9 (result $r)" test "$(ver alpha)" = 9
check "6.6 the release has VERSION 9, not the swapped file" test "$(srv "sudo cat /opt/tando/apps/alpha/releases/$ID/VERSION")" = 9
check "6.6 incoming did not change after the freeze" test "$(srv "sudo cat $INC/VERSION")" = 9
# any process of the deploy user, wherever it runs (as if it had code execution), ends too
srv "sudo -u tando-d-alpha sh -c 'cd /tmp && nohup sleep 900 > /dev/null 2>&1 &'"
check "6.6 (a stray process of tando-d-alpha is running)" test "$(srv 'pgrep -c -u tando-d-alpha sleep')" -ge 1
(cd "$E/w/alpha" && echo 9 > VERSION && CI=true as_key "$E/setup.alpha" "$R" deploy > "$E/d9b.out" 2>&1)
check "6.6 a deploy ends every other process of the deploy user" test "$(srv 'pgrep -c -u tando-d-alpha sleep')" = 0
check "6.6 ... and the deploy itself went through" has "$E/d9b.out" "live in"
# 6.7 the upload lease: held by key A, it blocks alpha only
TOK=$(begin_a)
check "6.7 (key A holds alpha's lease)" test -n "$TOK"
refused "6.7 a second begin while the lease is held" ka "sudo -n $AG begin alpha x"
for _ in 1 2 3 4 5; do ka "sudo -n $AG begin alpha x" > /dev/null 2>&1; done
(cd "$E/w/bravo" && echo 2 > VERSION && CI=true as_key "$E/setup.bravo" "$R" deploy > "$E/bravo.d" 2>&1)
check "6.7 bravo deploys with its key while alpha's lease is held (v$(ver bravo))" test "$(ver bravo)" = 2
refused "6.7 key B cannot end alpha's lease" kssh "$KB" tando-d-bravo "sudo -n $AG end alpha $TOK"
refused "6.7 key B cannot upload into alpha's lease" krsync "$KB" -rlptz "$E/up/x/" "tando-d-alpha@127.0.0.1:$INC"
(cd "$E/w/alpha" && "$R" unlock > "$E/unlock" 2>&1)
check "6.7 the admin clears the abandoned lease" has "$E/unlock" "cleared"
refused "6.7 after unlock, the old token cannot activate" ka "sudo -n $AG activate alpha $TOK 0 0"
check "6.7 alpha still answers v9" test "$(ver alpha)" = 9
# 6.9 a key's upload cannot outlive its lease into someone else's deploy
slow_upload() { # dir: throttled rsync into alpha's incoming with key A, in the background
  rsync -e "ssh ${KOPTS[*]} -i $KA -o ProxyCommand='perl $E/throttle.pl 127.0.0.1 $SP 40000'" -rlpt \
    "$1/" "tando-d-alpha@127.0.0.1:$INC" > "$E/slow.out" 2>&1 &
  SPID=$!; t_until 20 in_flight
}
TOK=$(begin_a); slow_upload "$E/up/b"
check "6.9 (a slow upload of key A is running)" test "$(srv "sudo ls -A $INC | grep -c '0big'")" -ge 1
end_a "$TOK"; wait $SPID; src=$?
check "6.9 ending the lease ends the key's uploads (rsync rc $src)" test "$src" != 0
TOK=$(begin_a); slow_upload "$E/up/b"
(cd "$E/w/alpha" && "$R" unlock > /dev/null 2>&1); wait $SPID; src=$?
check "6.9 the admin's unlock ends the key's uploads (rsync rc $src)" test "$src" != 0
TOK=$(begin_a); slow_upload "$E/up/b"
(cd "$E/w/alpha" && "$R" unlock > /dev/null 2>&1 && echo 10 > VERSION && "$R" deploy > "$E/d10.out" 2>&1)
wait $SPID
check "6.9 the admin's next deploy is the admin's upload: v10, no swapped file" sh -c "test '$(ver alpha)' = 10 &&
  test \"\$('$SSH' 'sudo cat /opt/tando/apps/alpha/current/VERSION')\" = 10"
TOK=$(begin_a); slow_upload "$E/up/b"
TOK2=$(ka "sudo -n $AG begin alpha x" 2> /dev/null | sed -n 's/^token=//p')
check "6.9 a refused second begin does not end the running upload" sh -c "test -z '$TOK2' && kill -0 $SPID"
end_a "$TOK"; wait $SPID
srv "sudo find $INC -name '.0big*' -delete; sudo rm -f $INC/0big.bin" > /dev/null 2>&1
# 6.8 root
check "6.8 no setuid/setgid file under /opt/tando (apps, ci homes)" \
  test "$(srv 'sudo find /opt/tando/apps /opt/tando/ci -perm /6000 | wc -l')" = 0
check "6.8 every sudo rule for deploy users names only tando-gate root <own app> <verb>" \
  test "$(srv 'sudo cat /etc/sudoers.d/tando-d-* | grep NOPASSWD | grep -v "^tando-d-\([a-z0-9-]*\) ALL=(root) NOPASSWD: /opt/tando/bin/tando-gate root \1 begin, /opt/tando/bin/tando-gate root \1 end, /opt/tando/bin/tando-gate root \1 activate, /opt/tando/bin/tando-gate root \1 receive, /opt/tando/bin/tando-gate root \1 preview-up, /opt/tando/bin/tando-gate root \1 preview-rm$" | wc -l')" = 0

# ---- 7. GitHub Actions workflow --------------------------------------------------------------
log "7. tando ci github"
RS=$E/tando-src
rm -rf "$RS" "${E:?}/tando.git"; mkdir -p "$RS"
cp -R "$T/bin" "$T/lib" "$T/server" "$T/templates" "$RS/"
( cd "$RS" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm tando && git tag v0.1-test ) || exit 1
git clone -q --bare "$RS" "$E/tando.git" && git -C "$E/tando.git" config uploadpack.allowAnySHA1InWant true
RSHA=$(git -C "$RS" rev-parse HEAD)
AR=$E/repo; rm -rf "$AR"; mkdir -p "$AR"; cp -R "$E/w/alpha" "$AR/alpha"; rm -rf "$AR/alpha/.tando" "$AR/alpha/BUILT"
echo 10 > "$AR/alpha/VERSION"
( cd "$AR" && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm app ) || exit 1
cd "$AR/alpha" || exit 1
refused "7a ci github refuses a moving branch as the tando ref" "$R" ci github --repo file:///e/tando.git --ref main
refused_by "7b without --repo, and no origin or release repository, ci github says where tando is missing from" \
  "cannot tell where the workflow should download tando from" env -u TANDO_REPO "$R" ci github
"$R" ci github --repo file:///e/tando.git > "$E/gh0.out" 2>&1
check "7b2 without --ref the workflow installs this tando' release (v\$(cat VERSION))" \
  grep -q "TANDO_FETCH: \"refs/tags/v$(tr -d ' \n' < "$T/VERSION")\"" "$AR/.github/workflows/deploy.yml"
# an install without templates/ (install.sh before it shipped them): a clear message
NT=$E/tree-notpl; rm -rf "$NT"; mkdir -p "$NT"; cp -R "$T/bin" "$T/lib" "$T/server" "$NT/"
refused_by "7b3 ci github on a tando without templates/ says so" "has no github-deploy.yml template.*reinstall" "$NT/bin/tando" ci github --force --repo file:///e/tando.git --ref "$(printf '%040d' 0)"
refused_by "7b4 ci hook on a tando without templates/ says so" "has no pre-push template.*reinstall" "$NT/bin/tando" ci hook
"$R" ci github --repo file:///e/tando.git --ref "$RSHA" --branch main --force > "$E/gh.out" 2>&1
check "7c ci github writes .github/workflows/deploy.yml" test -f "$AR/.github/workflows/deploy.yml"
WF=$AR/.github/workflows/deploy.yml
ruby -ryaml -e '
  w = YAML.load_file(ARGV[0]); on = w["on"] || w[true]; j = w["jobs"]["deploy"]; s = j["steps"]
  ok = {}
  ok["push only main"] = on["push"]["branches"] == ["main"]
  ok["job guard on the branch"] = j["if"] == "github.ref == '"'"'refs/heads/main'"'"'"
  ok["concurrency group, no cancel"] = w["concurrency"]["group"] == "tando-deploy-alpha" && w["concurrency"]["cancel-in-progress"] == false
  ok["read-only token"] = w["permissions"] == {"contents" => "read"}
  ok["checkout without persisted credentials"] = s[0]["uses"] =~ /^actions\/checkout@v\d/ && s[0]["with"]["persist-credentials"] == false
  n = s.find { |x| x["uses"].to_s =~ /setup-node/ }
  ok["setup-node with npm cache"] = n && n["with"]["cache"] == "npm" && n["with"]["cache-dependency-path"] == "alpha/package-lock.json"
  ok["npm ci"] = s.any? { |x| x["run"].to_s.strip == "npm ci --no-audit --no-fund" }
  i = s.find { |x| x["name"].to_s =~ /Install tando/ }
  ok["tando pinned to the commit"] = i && i["env"]["TANDO_SHA"] == ARGV[1] && i["env"]["TANDO_FETCH"] == ARGV[1] && i["run"].include?("expected $TANDO_SHA")
  d = s.last
  ok["deploy step: secrets only there, non-interactive (--yes)"] = d["run"] == "tando deploy --yes" && d["env"]["TANDO_DEPLOY_KEY"] == "${{ secrets.TANDO_DEPLOY_KEY }}" &&
    s[0..-2].none? { |x| x.to_s.include?("secrets.") }
  ok["working directory is the app"] = j["defaults"]["run"]["working-directory"] == "alpha"
  ok.each { |k, v| puts "#{v ? "PASS" : "FAIL"} 7d workflow: #{k}" }
' "$WF" "$RSHA" > "$E/yaml.out" 2>&1 || echo "FAIL 7d workflow YAML does not parse: $(tail -1 "$E/yaml.out")" >> "$E/yaml.out"
while IFS= read -r l; do case $l in PASS*) pass "${l#PASS }";; *) fail "${l#FAIL }";; esac; done < "$E/yaml.out"
if docker image inspect rhysd/actionlint:1.7.7 > /dev/null 2>&1 || docker pull -q rhysd/actionlint:1.7.7 > /dev/null 2>&1; then
  docker run --rm -v "$AR:/repo" -w /repo rhysd/actionlint:1.7.7 > "$E/actionlint.out" 2>&1; alrc=$?
  check "7e actionlint 1.7.7 finds no problem (rc $alrc) $(head -c 300 "$E/actionlint.out" | tr '\n' ' ')" test "$alrc" = 0
else
  fail "7e actionlint: could not pull rhysd/actionlint:1.7.7 (not validated)"
fi
# simulate the job: its run steps, in order, in a clean ubuntu-24.04-like container on the
# server's network; uses: steps are stood in for (checkout = git clone, setup-node = node in the image)
git clone -q --bare "$AR" "$E/app.git"
mkdir -p "$E/sim" && ruby -ryaml -e '
  w = YAML.load_file(ARGV[0]); j = w["jobs"]["deploy"]; wd = j["defaults"]["run"]["working-directory"]
  puts "set -e; export CI=true GITHUB_ACTIONS=true GITHUB_REF=refs/heads/main RUNNER_TEMP=$HOME/rt GITHUB_PATH=$HOME/gh_path"
  puts "mkdir -p $RUNNER_TEMP; : > $GITHUB_PATH"
  j["steps"].each_with_index do |s, i|
    puts "echo \"== step #{i}: #{s["name"]}\""
    if s["uses"].to_s.start_with?("actions/checkout@") then puts "git clone -q /e/app.git $HOME/ws"
    elsif s["uses"].to_s.start_with?("actions/setup-node@") then puts "node --version"
    elsif s["run"]
      env = (s["env"] || {}).map do |k, v|
        v = v.to_s.gsub(/\$\{\{\s*secrets\.([A-Z_]+)\s*\}\}/) { "${SECRET_#{$1}}" }
        abort "unsupported expression in #{k}" if v.include?("${{")
        "export #{k}=\"#{v}\"; "
      end
      File.write("#{ARGV[1]}/step#{i}.sh", s["run"])
      puts "( cd $HOME/ws/#{wd}; export PATH=\"$(tac $GITHUB_PATH | tr \"\\n\" :)$PATH\"; #{env.join} bash -eo pipefail /e/sim/step#{i}.sh )"
    else abort "unknown step #{s}" end
  end
' "$WF" "$E/sim" > "$E/sim/job.sh"
check "7f the job's steps translate to a script" test -s "$E/sim/job.sh"
# the secrets as GitHub would hold them: files here, environment inside the job, never argv
mkdir -p "$E/secrets"; chmod 700 "$E/secrets"
for n in TANDO_DEPLOY_KEY TANDO_KNOWN_HOSTS; do secret "$E/setup.alpha" $n > "$E/secrets/$n"; done
printf '127.0.0.1\n' > "$E/secrets/TANDO_HOST"; printf '22\n' > "$E/secrets/TANDO_PORT"
docker run --rm ${TANDO_TEST_RUN:+--label "tando.run=$TANDO_TEST_RUN"} --network "container:$TN" -v "$E:/e" -e HOME=/tmp/h tando-ci-runner:test bash -c \
  'for n in TANDO_DEPLOY_KEY TANDO_HOST TANDO_PORT TANDO_KNOWN_HOSTS; do export "SECRET_$n=$(cat /e/secrets/$n)"; done
   mkdir -p $HOME && bash /e/sim/job.sh' > "$E/sim.out" 2>&1
check "7g simulated job (clean ubuntu 24.04 container, deploy key): succeeds" test $? = 0
check "7h ... installed tando at the pinned commit" has "$E/sim.out" "tando $RSHA"
check "7i ... alpha answers v10 from the CI build" test "$(ver alpha)" = 10
check "7j ... the build ran in CI" test "$(srv 'sudo cat /opt/tando/apps/alpha/current/BUILT')" = "built 10"
check "7k ... the job log is plain and has no private key" eval 'plain "$E/sim.out" && ! grep -q "PRIVATE KEY" "$E/sim.out"'

# ---- 8. pre-push hook ------------------------------------------------------------------------
log "8. tando ci hook"
HR=$E/hook; rm -rf "$HR" "${E:?}/remote.git"; mkdir -p "$HR"; cp -R "$E/w/alpha" "$HR/alpha"; rm -rf "${HR:?}/alpha/.tando" "${HR:?}/alpha/BUILT"
# the developer first deploys from this repository (tando remembers where an app comes from)
echo 10 > "$HR/alpha/VERSION"
(cd "$HR/alpha" && "$R" deploy --force > "$E/hook.adopt" 2>&1)
rm -rf "${HR:?}/alpha/.tando" "${HR:?}/alpha/BUILT"
check "8a0 (the app is now deployed from the hook's repository: v10)" test "$(ver alpha)" = 10
echo 11 > "$HR/alpha/VERSION"
git init -q --bare -b main "$E/remote.git"
( cd "$HR" && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm v11 &&
  git remote add origin "$E/remote.git" ) || exit 1
cd "$HR/alpha" || exit 1
"$R" ci hook --branch main > "$E/hook.inst" 2>&1
check "8a ci hook installs .git/hooks/pre-push" test -x "$HR/.git/hooks/pre-push"
check "8a1 the hook deploys non-interactively, as the repository (--yes, TANDO_ORIGIN)" \
  sh -c "grep -q 'TANDO_ORIGIN=.* deploy --yes' '$HR/.git/hooks/pre-push'"
check "8b ... and says the deploy happens before the push reaches the remote" has "$E/hook.inst" "before the push reaches the remote"
echo 99 > VERSION                     # dirty: must not be deployed
git -c user.name=t -c user.email=t@t push -q origin main > "$E/push1" 2>&1
check "8c push main: deployed the pushed commit (v11), not the dirty tree (99)" test "$(ver alpha)" = 11
check "8d ... warned about the uncommitted change" has "$E/push1" "uncommitted changes; they are NOT deployed"
check "8e ... said the deploy runs before the push reaches origin" has "$E/push1" "before the push reaches origin"
check "8f ... and the push went through" test "$(git -C "$E/remote.git" rev-parse main)" = "$(git rev-parse HEAD)"
check "8g ... and the temporary worktree is gone" test "$(git worktree list | wc -l | tr -d ' ')" = 1
git checkout -q VERSION
git checkout -q -b feature && echo 12 > VERSION && git -c user.name=t -c user.email=t@t commit -qam v12
git push -q origin feature > "$E/push2" 2>&1
check "8h push of another branch does not deploy (still v11)" test "$(ver alpha)" = 11
git checkout -q main
"$R" env set CRASH_VERSION=13 > /dev/null 2>&1
echo 13 > VERSION && git -c user.name=t -c user.email=t@t commit -qam v13
git push -q origin main > "$E/push3" 2>&1; prc=$?
check "8i a failed deploy does not block the push by default (rc $prc)" sh -c "test $prc = 0 && test '$(git -C "$E/remote.git" rev-parse main)' = '$(git rev-parse HEAD)'"
check "8j ... says so, and alpha keeps serving v11" sh -c "grep -q 'deploy failed; the push continues' '$E/push3' && test '$(ver alpha)' = 11"
git config tando.hookstrict true
echo 13 > VERSION && echo '// b' >> server.js && git -c user.name=t -c user.email=t@t commit -qam v13b
git push -q origin main > "$E/push4" 2>&1; prc=$?
check "8k with tando.hookstrict a failed deploy refuses the push" sh -c "test $prc != 0 && test '$(git -C "$E/remote.git" rev-parse main)' != '$(git rev-parse HEAD)'"
"$R" env unset CRASH_VERSION > /dev/null 2>&1
git config tando.hookdirty refuse; echo 77 > VERSION
git push -q origin main > "$E/push5" 2>&1; prc=$?
check "8l with tando.hookdirty refuse a dirty tree refuses the push" sh -c "test $prc != 0 && grep -q 'push refused' '$E/push5'"
git checkout -q VERSION; git config --unset tando.hookdirty
git push -q origin main > "$E/push6" 2>&1
check "8m clean tree, strict, healthy commit: deploys v13 and pushes" sh -c "test '$(ver alpha)' = 13 && test '$(git -C "$E/remote.git" rev-parse main)' = '$(git rev-parse HEAD)'"
"$R" ci hook --remove > /dev/null 2>&1
check "8n ci hook --remove" test ! -e "$HR/.git/hooks/pre-push"

# ---- 9. the security review (docs/SECURITY-REVIEW-CI.md) -----------------------------------
# F3 runs the reviewer's own script (test/.work-sec-ci/attacks/f3-remote.sh, unchanged) on the
# server with only alpha's key, then checks the server's state. The other findings are checked
# by the property each fix establishes.
log "9. security review findings"
cd "$E/w/alpha" || exit 1
KUID=$(srv 'id -u tando-d-alpha')
# cron and at, to test that revoke clears them: in the test server's image (test/server/Dockerfile);
# on a server without them (an image built before they were added) installed now, from the mirror
srv 'command -v crontab > /dev/null && command -v at > /dev/null || { sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron at; } > /dev/null 2>&1'
ATK=$ROOT/test/.work-sec-ci/attacks
if [ -f "$ATK/f3-remote.sh" ] && [ -f "$ATK/f3-kssh" ]; then
  srv 'cat > ~/kssh && chmod 755 ~/kssh' < "$ATK/f3-kssh"
  srv 'cat > ~/f3-remote.sh' < "$ATK/f3-remote.sh"
  srv 'cat > ~/ka && chmod 600 ~/ka' < "$KA"
  srv 'bash ~/f3-remote.sh' > "$E/f3.out" 2>&1
  check "9.F3a the reviewer's chain runs no code as the deploy user" \
    srv_no 'test -e /tmp/rce-deploy-user'
  check "9.F3b no process of tando-d-alpha is left" test "$(srv 'pgrep -c -u tando-d-alpha')" = 0
  check "9.F3c no unit landed under /run/user/$KUID" srv_no "sudo test -e /run/user/$KUID/systemd"
  check "9.F3d the planted link was removed from incoming/" srv_no "sudo test -L $INC/r"
  srv 'rm -f ~/ka ~/kssh ~/f3-remote.sh; rm -rf ~/p1 ~/p2' > /dev/null 2>&1
else
  skip "9.F3a the reviewer's scripts are not in test/.work-sec-ci/attacks"
fi
check "9.F3e the deploy user's systemd user manager is masked" \
  test "$(srv "systemctl is-enabled user@$KUID.service 2>/dev/null")" = masked
check "9.F3f no lingering for the deploy user" srv_no 'test -e /var/lib/systemd/linger/tando-d-alpha'
check "9.F3g cron.deny and at.deny name the deploy user" \
  sh -c "'$SSH' 'sudo grep -qx tando-d-alpha /etc/cron.deny && sudo grep -qx tando-d-alpha /etc/at.deny'"
# F8: root mode is bound to the ssh session that sshd started for a key
denied_as tando-d-alpha "9.F8a the deploy user cannot read its key ids" cat /opt/tando/ci/alpha/.ssh/authorized_keys
KIDA=$(srv "sudo cut -f1 /opt/tando/ci/alpha/keys | head -1")
refused_by "9.F8b root mode from a process of the deploy user outside a key session is refused" \
  "not called from a deploy key's ssh session" \
  srv "sudo -u tando-d-alpha sudo -n /opt/tando/bin/tando-gate root alpha begin < /dev/null"
check "9.F8c ... and took no lease" srv_no "sudo grep -q ci-$KIDA /opt/tando/apps/alpha/upload 2>/dev/null"
# code review S-B4: the session cgroups are found (set -f does not leave the glob literal)
# (the control socket in a short directory of its own: a unix socket path has at most 104 bytes,
# and ssh adds 17 to it while it sets up; a deep work directory made this check fail)
CPD=$(mktemp -d /tmp/tando-cm.XXXXXX); CP=$CPD/a
ssh "${KOPTS[@]}" -i "$KA" -M -S "$CP" -N -f tando-d-alpha@127.0.0.1 > "$E/n1a.out" 2>&1
t_until 10 eval 'ssh -S "$CP" -O check x > /dev/null 2>&1'
check "9.N1a (an idle second session of alpha's key is open$(head -c 100 "$E/n1a.out" | tr '\n' ' '))" sh -c "ssh -S '$CP' -O check x > /dev/null 2>&1"
TOK=$(begin_a)
check "9.N1b begin ends it through its cgroup (journal: ended N other sessions)" \
  sh -c "'$SSH' 'sudo journalctl -t tando-gate --no-pager -o cat' | grep -q 'tando-d-alpha: ended [1-9]'"
check "9.N1c ... and it is gone" sh -c "! ssh -S '$CP' -O check x > /dev/null 2>&1"
ssh -S "$CP" -O exit x > /dev/null 2>&1; rm -rf "${CPD:?}"
end_a "$TOK"
# code review S-B4: host setup refreshes existing deploy users (the "$CI"/*/keys glob)
srv "sudo sed -i '/^tando-d-alpha\$/d' /etc/at.deny; sudo chmod 644 /opt/tando/ci/alpha/.ssh/authorized_keys"
"$R" host setup test public_port="$HP" > /dev/null 2>&1
check "9.N1d host setup restores an existing deploy user's layout" \
  sh -c "'$SSH' 'sudo grep -qx tando-d-alpha /etc/at.deny && test \$(sudo stat -c %a /opt/tando/ci/alpha/.ssh/authorized_keys) = 640'"  # lint: allow RL02 runs on the Linux server
# code review B4: a value ending in "=" keeps it (the gate's kv, run here)
printf 'a=b=\n' > "$E/kv.t"
if [ -f "$T/server/tando-gate" ]; then
  check "9.N3 the gate's kv keeps a trailing =" test "$(bash -c "$(sed -n '/^kv()/,/^}/p' "$T/server/tando-gate"); kv '$E/kv.t' a")" = "b="
else   # the Go gate's reader (srv/gate/conf.go), by its unit test
  check "9.N3 the gate's kv keeps a trailing = (srv/gate TestKV)" sh -c "cd '$ROOT/srv' && GOTOOLCHAIN=local go test -count=1 -run '^TestKV\$' ./gate > /dev/null"
fi
# F4: end checks the token before stopping anything
TOK=$(begin_a)
refused_by "9.F4 end with a token that is not the lease's is refused before anything stops" \
  "no upload lease of this key with that token" \
  sh -c "echo 00000000-0000-0000-0000-000000000000 | ssh ${KOPTS[*]} -i '$KA' tando-d-alpha@127.0.0.1 'sudo -n $AG end alpha'"
end_a "$TOK"
# F6: limits enforced while the upload runs, one receiver per app
srv "printf 'ci_max_file_mb=8\nci_max_mb=24\n' | sudo tee -a /opt/tando/host.conf > /dev/null"
rm -rf "${E:?}/big"; mkdir -p "$E/big"; head -c 12000000 /dev/zero > "$E/big/one.bin"
TOK=$(begin_a)
refused "9.F6a a file over the per-file limit is cut off by the kernel" krsync "$KA" -rlptz "$E/big/" "tando-d-alpha@127.0.0.1:$INC"
check "9.F6b ... and nothing over the limit stays in incoming/" \
  test "$(srv "sudo find $INC -size +8M | wc -l")" = 0
end_a "$TOK"
rm -rf "${E:?}/big"; mkdir -p "$E/big"; for i in 1 2 3 4; do head -c 7000000 /dev/urandom > "$E/big/f$i.bin"; done
TOK=$(begin_a)
refused_by "9.F6c an upload over the app's total limit is stopped" "upload stopped: incoming/ holds more than" \
  krsync "$KA" -rlpt "$E/big/" "tando-d-alpha@127.0.0.1:$INC"
end_a "$TOK"
srv "sudo find $INC -name 'f?.bin' -delete; sudo find $INC -name '.f?.bin.*' -delete" > /dev/null 2>&1
srv "printf 'ci_max_files=0300\n' | sudo tee -a /opt/tando/host.conf > /dev/null"
rm -rf "${E:?}/many"; mkdir -p "$E/many"; for i in $(seq 1 900); do echo "$i" > "$E/many/f$i"; done
TOK=$(begin_a)
refused_by "9.F6e an upload over the file-count limit (0300, leading zero) is stopped" "upload stopped: incoming/ holds more than 300 files" \
  krsync "$KA" -rlpt "$E/many/" "tando-d-alpha@127.0.0.1:$INC"
end_a "$TOK"
srv "sudo find $INC -maxdepth 1 -name 'f[0-9]*' -delete" > /dev/null 2>&1
srv "sudo sed -i '/^ci_max_/d' /opt/tando/host.conf; sudo find $INC -name 'f?.bin' -delete; sudo find $INC -name '.f?.bin.*' -delete; sudo rm -f $INC/one.bin" > /dev/null 2>&1
TOK=$(begin_a)
slow_upload "$E/up/b"
refused_by "9.F6d a second receiver under the same lease is refused" "another upload of alpha is running" \
  ka "rsync --server -ltprz . $INC" < /dev/null
end_a "$TOK"; wait $SPID
srv "sudo find $INC -name '.0big*' -delete; sudo rm -f $INC/0big.bin" > /dev/null 2>&1
# F10: the client's locale variables do not reach the gate's shell
LC_ALL=/opt/tando/apps/alpha/incoming/x ssh "${KOPTS[@]}" -i "$KA" -o SendEnv=LC_ALL tando-d-alpha@127.0.0.1 "$AG info" > /dev/null 2> "$E/f10.err"
check "9.F10a a client LC_ALL is not parsed (no setlocale warning)" hasnt "$E/f10.err" "setlocale"
check "9.F10b sshd forces LC_ALL=C for deploy users" grep -q '^setenv LC_ALL=C' "$E/sshd.d"
# F5 (gate side): a symlink that leaves incoming/ is refused before root copies anything
fresh; ln -s ../../bravo/shared/data/db.json "$E/up/a/image-ref"; PREP="" up_attack "9.F5 relative symlink out of incoming/" "symlink leaves the upload"
# F11 and F8 eviction, on bravo: revoke ends the key's lease and everything of its deploy user
TOKB=$(kssh "$KB" tando-d-bravo "sudo -n $AG begin bravo x" 2> /dev/null | sed -n 's/^token=//p')
srv "sudo -u tando-d-bravo sh -c 'cd /tmp && nohup sleep 900 > /dev/null 2>&1 &'; sudo -u tando-d-bravo touch /tmp/f8-bravo /dev/shm/f8-bravo"
CRON=0
srv 'command -v crontab > /dev/null' && CRON=1
[ $CRON = 1 ] && srv "echo '* * * * * true' | sudo crontab -u tando-d-bravo -" > /dev/null 2>&1
srv "sudo -u tando-d-bravo-2 sh -c 'cd /tmp && nohup sleep 901 > /dev/null 2>&1 &'"
(cd "$E/w/bravo" && "$R" ci revoke all > /dev/null 2>&1)
check "9.N5a revoking bravo leaves bravo-2's deploy user running" test "$(srv 'pgrep -c -u tando-d-bravo-2')" -ge 1
check "9.N5b ... and bravo-2's key still works" test "$(kssh "$KB2" tando-d-bravo-2 "$AG info" | grep -c arch)" = 1
srv "sudo pkill -u tando-d-bravo-2 sleep" > /dev/null 2>&1
check "9.F11 revoke ends the revoked key's lease" sh -c "test -n '$TOKB' && ! '$SSH' 'sudo grep -q ci- /opt/tando/apps/bravo/upload 2>/dev/null'"
check "9.F8d revoke ends every process of the deploy user" test "$(srv 'pgrep -c -u tando-d-bravo')" = 0
check "9.F8e revoke removes its files in /tmp and /dev/shm" srv_no 'ls /tmp/f8-bravo /dev/shm/f8-bravo'
if [ $CRON = 1 ]; then
  check "9.F8f revoke removes its crontab" srv_no 'sudo crontab -l -u tando-d-bravo'
else
  skip "9.F8f crontab: cron is not installed on this test server"
fi

# ---- 10. receiver races (regressions) --------------------------------------------------------
# The receiver unit has a fixed name (one per app); systemd collects an ended one a moment later
# and refuses the name until then. Uploads back to back in one lease, and an upload right after
# `end`, must never meet the previous receiver (TANDO_CI_RACE_N rounds, default 200).
log "10. receiver races"
RN=${TANDO_CI_RACE_N:-200}
rm -rf "${E:?}/race"; mkdir -p "$E/race"
TOK=$(begin_a); bad=0
for i in $(seq 1 "$RN"); do
  echo "$i" > "$E/race/n"
  krsync "$KA" -rlptc "$E/race/" "tando-d-alpha@127.0.0.1:$INC" > "$E/race.out" 2>&1 ||
    { bad=$((bad + 1)); [ $bad = 1 ] && cp "$E/race.out" "$E/race.first"; }
done
end_a "$TOK"
check "10a $RN uploads back to back in one lease all succeed ($bad failed$( [ $bad = 0 ] || printf ': %s' "$(head -c 120 "$E/race.first" | tr '\n' ' ')"))" test $bad = 0
bad=0 n2=$((RN / 4))
for i in $(seq 1 "$n2"); do
  echo "e$i" > "$E/race/n"
  TOK=$(begin_a)
  krsync "$KA" -rlptc "$E/race/" "tando-d-alpha@127.0.0.1:$INC" > "$E/race.out" 2>&1 ||
    { bad=$((bad + 1)); [ $bad = 1 ] && cp "$E/race.out" "$E/race.first"; }
  end_a "$TOK"
done
check "10b $n2 rounds of begin, upload, end: the upload right after end always starts ($bad failed$( [ $bad = 0 ] || printf ': %s' "$(head -c 120 "$E/race.first" | tr '\n' ' ')"))" test $bad = 0
check "10c the last upload's content arrived" test "$(srv "sudo cat $INC/n")" = "e$n2"
srv "sudo rm -f $INC/n" > /dev/null 2>&1
# after end returns, nothing of that upload session writes incoming/ any more: a slow upload is
# running, end; then incoming/ stays as it is, and the receiver's ticket is gone (a receiver whose
# unit systemd were still creating would refuse to start)
TOK=$(begin_a); slow_upload "$E/up/b"
end_a "$TOK"
srv "sudo touch /opt/tando/ci/alpha/.after-end" > /dev/null 2>&1
sleep 3
wait $SPID 2> /dev/null
check "10d after end returns, nothing more is written into incoming/" \
  test "$(srv "sudo find $INC -newer /opt/tando/ci/alpha/.after-end | wc -l")" = 0
check "10e ... the receiver's ticket is gone and no receiver runs" \
  srv_no "sudo test -e /opt/tando/ci/alpha/receiver || systemctl list-units --all --plain --no-legend 'tando-rx-alpha.service' 'tando-rx-alpha@*.service' | grep -Eq ' (active|activating|reloading) '"
srv "sudo rm -f /opt/tando/ci/alpha/.after-end; sudo find $INC -name '.0big*' -delete; sudo rm -f $INC/0big.bin" > /dev/null 2>&1

# ---- 11. preview apps (tando preview; docs/PREVIEWS.md) -------------------------------------------
# alpha's key makes, deploys and removes alpha-<branch> only; the admin does the same without a key.
log "11. previews"
cd "$E/w/alpha" || exit 1
conf_set tando.conf preview_skip SECRET_A
# what a preview gets: only the names preview_env lists, never a database URL or a value that names
# alpha's own data, and no release command (migrations) by default
conf_set tando.conf preview_env "KEEP_A, SECRET_A, DATABASE_URL, LEAK_URL"
conf_set tando.conf release "true"
"$R" env set KEEP_A=kept-value > /dev/null 2>&1
"$R" env set OTHER_B=not-listed > /dev/null 2>&1
"$R" env set DATABASE_URL=postgres://prod:pw@db.example.org/prod > /dev/null 2>&1
"$R" env set LEAK_URL=postgres://tando_alpha:pw@127.0.0.1/tando_alpha > /dev/null 2>&1
echo 9 > VERSION
"$R" deploy --force > "$E/pv.d9" 2>&1       # (configure: alpha's preview_skip reaches the server; --force: the hook section deployed it from elsewhere)
check "11a preview_skip reaches the server (app.conf of alpha)" srv "sudo grep -qx preview_skip=SECRET_A /opt/tando/apps/alpha/app.conf"
echo 10 > VERSION
"$R" preview up --branch feature/Login > "$E/pv.up" 2>&1; rc=$?
PV=$("$R" preview ls --json 2> /dev/null | sed -n 's/.*"name":"\([a-z0-9-]*\)".*/\1/p' | head -1)
check "11b admin: tando preview up deploys the branch as its own app ($PV, rc=$rc)" \
  eval 'test $rc = 0 && printf "%s" "$PV" | grep -Eq "^alpha-feature-login-[0-9a-f]{4}$" && test "$(ver "$PV")" = 10'
check "11c the preview has alpha's env except what preview_skip names" \
  eval 'srv "sudo cat /opt/tando/apps/$PV/env" | grep -q "^KEEP_A=\"kept-value\"" && ! srv "sudo cat /opt/tando/apps/$PV/env" | grep -q SECRET_A'
srv "sudo cat /opt/tando/apps/$PV/env" > "$E/pv.env" 2>&1
check "11c2 ... only what preview_env names: not OTHER_B, never DATABASE_URL (an external one too), nor a value naming alpha's database ($(cut -d= -f1 "$E/pv.env" | tr '\n' ' '))" \
  eval '! grep -q "^OTHER_B=" "$E/pv.env" && ! grep -q "^DATABASE_URL=" "$E/pv.env" && ! grep -q "^LEAK_URL=" "$E/pv.env"'
check "11c3 ... and no release command (alpha has one; preview_release is off by default)" \
  eval 'srv "sudo grep -qx release=true /opt/tando/apps/alpha/app.conf" && srv_no "sudo grep -q ^release /opt/tando/apps/$PV/app.conf"'
check "11d ... idle_stop 6h, no backup, no database, no jobs, an expiry about 7 days out" eval '
  c=$(srv "sudo cat /opt/tando/apps/$PV/app.conf"); x=$(printf "%s\n" "$c" | sed -n "s/^preview_expires=//p"); n=$(srv "date +%s")
  printf "%s\n" "$c" | grep -qx idle_stop=6h && printf "%s\n" "$c" | grep -qx backup=off && ! printf "%s\n" "$c" | grep -q "^database=\|^job\." &&
  test "$((x - n))" -gt 604000 && test "$((x - n))" -le 604800'
check "11e the hourly expiry timer is enabled on the server" srv "systemctl is-enabled -q tando-previews.timer"
"$R" preview ls > "$E/pv.ls" 2>&1
check "11f tando preview ls lists it with its link" sh -c "grep -q '$PV' '$E/pv.ls' && grep -q 'localhost' '$E/pv.ls'"
check "11g the parent app is untouched (alpha still v9)" test "$(ver alpha)" = 9
# the deploy key: pull request opened -> deploy; closed -> remove
echo 11 > VERSION
CI=true GITHUB_HEAD_REF=pr-7 as_key "$E/setup.alpha" "$R" preview up > "$E/pv.key" 2>&1; rc=$?
check "11h a CI deploy key makes and deploys alpha-pr-7 (rc=$rc)" eval 'test $rc = 0 && test "$(ver alpha-pr-7)" = 11'
check "11i ... as a deploy user of its own with the same key (tando-d-alpha-pr-7, one key line)" \
  eval 'test "$(srv "getent passwd tando-d-alpha-pr-7 | cut -d: -f7; sudo grep -c ssh-ed25519 /opt/tando/ci/alpha-pr-7/.ssh/authorized_keys" | tr "\n" " ")" = "/opt/tando/bin/tando-gate 1 "'
echo 12 > VERSION
CI=true GITHUB_HEAD_REF=pr-7 as_key "$E/setup.alpha" "$R" preview up > "$E/pv.key2" 2>&1
check "11j pushing to the pull request again updates the same preview (v12)" test "$(ver alpha-pr-7)" = 12
# what the key may not do: other names, other apps' previews, the admin's verbs
for v in "preview-up alpha bravo-x" "preview-up alpha alpha" "preview-up alpha alpha-" "preview-up alpha alpha-X" "preview-up alpha alpha--x" \
    "preview-up alpha alpha-ok 0d" "preview-up bravo bravo-x" "preview-rm alpha bravo" "preview-rm alpha alpha" "preview-rm bravo bravo-2" \
    "preview-ls alpha" "preview-sweep" "destroy alpha-pr-7 purge" "preview-up alpha alpha-aaaaaaaaaaaaaaaaaaaa"; do
  refused "11k key of alpha cannot run '$v'" ka "sudo -n $AG $v"
done
refused_by "11l alpha's key cannot make a preview of another app (bravo-x)" "previews named alpha-<name> only" ka "sudo -n $AG preview-up alpha bravo-x"
check "11m ... and made none" srv_no "sudo test -e /opt/tando/apps/bravo-x/app.conf"
refused "11n the key of bravo-2 cannot log in as a preview of alpha" kssh "$KB2" tando-d-alpha-pr-7 "$AG info"
refused "11o alpha's preview user cannot make previews of its own (previews have no previews)" kssh "$KA" tando-d-alpha-pr-7 "sudo -n $AG preview-up alpha-pr-7 alpha-pr-7-x"
refused_by "11p ... nor deploy to alpha itself (its key may deploy alpha-pr-7 only)" "this key deploys alpha-pr-7 only" \
  kssh "$KA" tando-d-alpha-pr-7 "sudo -n $AG begin alpha x"
refused_by "11q a preview has no previews (the server refuses)" "is itself a preview" kssh "$KA" tando-d-alpha-pr-7 "sudo -n $AG preview-up alpha-pr-7 alpha-pr-7-x"
# remove: with the key (pull request closed), and as the admin
CI=true GITHUB_HEAD_REF=pr-7 as_key "$E/setup.alpha" "$R" preview rm > "$E/pv.rm" 2>&1; rc=$?
check "11r the key removes alpha-pr-7 (rc=$rc): app, deploy user and sudo rule are gone" \
  eval 'test $rc = 0 && srv_no "sudo test -e /opt/tando/apps/alpha-pr-7/app.conf" && srv_no "getent passwd tando-d-alpha-pr-7" &&
        srv_no "sudo test -e /etc/sudoers.d/tando-d-alpha-pr-7" && srv_no "sudo test -e /opt/tando/ci/alpha-pr-7"'
check "11s ... and the key still deploys alpha" eval 'echo 13 > VERSION; CI=true as_key "$E/setup.alpha" "$R" deploy > "$E/pv.d13" 2>&1; test "$(ver alpha)" = 13'
"$R" preview rm --branch feature/Login > "$E/pv.rm2" 2>&1; rc=$?
check "11t the admin removes the other preview (rc=$rc)" eval 'test $rc = 0 && srv_no "sudo test -e /opt/tando/apps/$PV/app.conf"'
# expiry: the sweep (tando-previews.timer runs it every hour) removes an expired preview, never a live one
srv "sudo $AG preview-up alpha alpha-ttl 2s" > /dev/null 2>&1
srv "sudo $AG preview-up alpha alpha-keep 3d" > /dev/null 2>&1
check "11u an expired preview is removed by the sweep, one that is not stays" \
  eval 't_until 30 eval "srv \"sudo $AG preview-sweep\" | grep -qx removed=1" && srv_no "sudo test -e /opt/tando/apps/alpha-ttl/app.conf" &&
        srv "sudo test -f /opt/tando/apps/alpha-keep/app.conf"'
srv "sudo $AG preview-rm alpha alpha-keep" > /dev/null 2>&1
# a key that is revoked or rotated stops working for the previews too
CI=true GITHUB_HEAD_REF=pr-8 as_key "$E/setup.alpha" "$R" preview up > "$E/pv.pr8" 2>&1
check "11v pr-8 deployed (v13)" test "$(ver alpha-pr-8)" = 13
check "11w its key works as the preview's user" eval 'test "$(kssh "$KA" tando-d-alpha-pr-8 "$AG info" | grep -c arch)" = 1'
(cd "$E/w/alpha" && "$R" ci rotate > "$E/setup.alpha2" 2> /dev/null)
refused "11x after ci rotate the old key no longer works as the preview's user" kssh "$KA" tando-d-alpha-pr-8 "$AG info"
KA2=$E/key.alpha2; secret "$E/setup.alpha2" TANDO_DEPLOY_KEY > "$KA2"; chmod 600 "$KA2"
check "11y ... the new key does" eval 'test "$(kssh "$KA2" tando-d-alpha-pr-8 "$AG info" | grep -c arch)" = 1'
"$R" preview rm --branch pr-8 > /dev/null 2>&1

# ---- 12. previews: the previews key, the creation race, a destroyed parent ---------------------------
log "12. previews: key scope, race, destroy"
cd "$E/w/alpha" || exit 1
# 12a. the key for pull requests (tando ci setup --previews) makes previews, never deploys alpha
"$R" ci setup --previews > "$E/setup.pv" 2> "$E/setup.pv.err"; rc=$?
KP=$E/key.pv; secret "$E/setup.pv" TANDO_DEPLOY_KEY > "$KP"; chmod 600 "$KP"
echo 14 > VERSION
CI=true GITHUB_HEAD_REF=pr-9 as_key "$E/setup.pv" "$R" preview up > "$E/pv.k9" 2>&1; rc2=$?; cat "$E/pv.k9" >&2
check "12a a previews key (setup rc=$rc) makes and deploys alpha-pr-9 (rc=$rc2)" eval 'test $rc/$rc2 = 0/0 && test "$(ver alpha-pr-9)" = 14'
vb=$(ver alpha)
echo 15 > VERSION
CI=true as_key "$E/setup.pv" "$R" deploy > "$E/pv.kdeploy" 2>&1; rc=$?; cat "$E/pv.kdeploy" >&2
check "12b ... but it cannot deploy alpha itself (rc=$rc, alpha stays v$vb)" \
  eval 'test $rc != 0 && test "$(ver alpha)" = "$vb" && grep -q "deploys previews of alpha only" "$E/pv.kdeploy"'
refused_by "12c ... root mode refuses it alpha's upload lease" "deploys previews of alpha only" kssh "$KP" tando-d-alpha "sudo -n $AG begin alpha x"
"$R" ci ls > "$E/ci-ls.out" 2>&1
check "12d tando ci ls says which key deploys and which makes previews only" \
  eval 'grep -q "previews" "$E/ci-ls.out" && grep -q "deploy" "$E/ci-ls.out"'
# 12e. revoking the previews key: its copy on alpha-pr-9's user goes too
"$R" ci revoke "$(ssh-keygen -lf "$KP" | awk '{ print $2 }')" > "$E/revoke.pv" 2>&1; rc=$?
refused "12e after ci revoke (rc=$rc) the previews key no longer works as alpha-pr-9's user" kssh "$KP" tando-d-alpha-pr-9 "$AG info"
# 12f. the creation race: an app made under the preview's name between the check and the creation is
# never taken over (the agent waits at the fault point pv.checked while the admin creates it)
srv "sudo install -m 644 -o root -g root /dev/null /etc/tando-test-server && sudo install -d -m 700 -o root -g root /run/tando-test &&
     printf 'point=pv.checked\naction=hang\nverb=preview-up\n' | sudo tee /run/tando-test/fault > /dev/null"
srv "sudo $AG preview-up alpha alpha-race" > "$E/race.pv" 2>&1 &
rp=$!
t_until 30 eval 'srv "sudo test -e /run/tando-test/reached"'
srv "sudo grep -E '^(recipe|start)=' /opt/tando/apps/alpha/app.conf | sudo $AG configure alpha-race" > "$E/race.conf" 2>&1
srv "sudo touch /run/tando-test/release"
wait $rp; rc=$?
srv "sudo rm -rf /run/tando-test /etc/tando-test-server"
cat "$E/race.pv" "$E/race.conf" >&2
check "12f a preview whose name an admin's app took in the meantime fails (rc=$rc) and leaves that app as it was (no preview_of, no expiry)" \
  eval 'test $rc != 0 && srv "sudo test -f /opt/tando/apps/alpha-race/app.conf" && srv_no "sudo grep -q ^preview_ /opt/tando/apps/alpha-race/app.conf"'
srv "sudo $AG destroy alpha-race purge" > /dev/null 2>&1
# 12g. destroying the parent destroys its previews (and with them the copies of its keys)
"$R" preview up --branch gone > /dev/null 2>&1
srv "sudo $AG destroy alpha purge" > "$E/destroy.alpha" 2>&1; rc=$?; cat "$E/destroy.alpha" >&2
check "12g destroying alpha (rc=$rc) destroys its previews alpha-gone and alpha-pr-9 first: apps, deploy users, key copies" \
  eval 'test $rc = 0 && srv_no "sudo test -e /opt/tando/apps/alpha-gone/app.conf" && srv_no "sudo test -e /opt/tando/apps/alpha-pr-9/app.conf" &&
        srv_no "getent passwd tando-d-alpha-pr-9" && srv_no "sudo test -e /opt/tando/ci/alpha-pr-9/keys"'

echo
echo "$PASSES passed, $FAILS failed"
[ $FAILS = 0 ]
