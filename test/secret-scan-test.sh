#!/bin/bash
# test/secret-scan-test.sh: scripts/secret-scan.sh finds every kind it claims, prints no value, and
# leaves placeholders alone. The fixtures are made here, in a temporary directory, from pieces, so
# no secret-looking value is ever in the repository (this file must pass the scan itself).
# No server, no network. One PASS/FAIL line each; run by test/lint.sh on whole-tree runs.
# Usage: test/secret-scan-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
SCAN=$ROOT/scripts/secret-scan.sh
W=$(mktemp -d "${TMPDIR:-/tmp}/secret-scan-test.XXXXXX") || exit 2
trap 'rm -rf "$W"' EXIT
fails=0 n=0
check() { # name command...
  local name=$1; shift
  n=$((n + 1))
  if "$@" > /dev/null 2>&1; then echo "PASS $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi
}
# hex <n>: n random hex characters, starting with a letter and a digit
hex() { printf 'a1%s' "$(od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n' | cut -c1-$(($1 - 2)))"; }
# b32 <n>: n random characters of the recovery-key alphabet
b32() { LC_ALL=C tr -dc 'a-z2-7' < /dev/urandom | head -c "$1"; }
alnum() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }

mkdir -p "$W/hit" "$W/clean"
B='-----BEGIN' K='PRIVATE KEY-----'
printf 'x\n%s OPENSSH %s\nAAAA\n' "$B" "$K"                       > "$W/hit/private-key"
printf 'key: %s%s\n' AKIA "$(alnum 16 | tr 'a-z' 'A-Z')"             > "$W/hit/aws-key-id"
printf 'aws_secret_access_key = %s\n' "$(hex 40)"                    > "$W/hit/access-secret"
printf 'export GH=%s_%s\n' ghp "$(alnum 36)"                          > "$W/hit/github-token"
printf 'SLACK=%s-%s-%s\n' xoxb "$(hex 12)" "$(hex 24)"                > "$W/hit/slack-token"
printf 'url=https://hooks.%s.com/services/T%s/B%s/%s\n' slack "$(hex 8)" "$(hex 8)" "$(hex 24)" > "$W/hit/webhook-url"
printf 'token=%s_%s\ntopic=https://ntfy.%s/alerts-%s\n' tk "$(b32 29)" sh "$(hex 10)" > "$W/hit/ntfy"
printf 'DATABASE_URL=postgres://app:%s@10.0.0.5:5432/app\n' "$(hex 14)" > "$W/hit/url-credentials"
printf 'curl "https://api.service.io/v1/x?token=%s"\n' "$(hex 24)"   > "$W/hit/token-param"
printf 'DB_PASSWORD=%s\n' "$(hex 14)"                                 > "$W/hit/password"
rk=tando-key-$(b32 4); for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13; do rk=$rk-$(b32 4); done
printf 'key %s\n' "$rk"                                               > "$W/hit/recovery-key"
printf 'ssh admin@%s.%s\n' 11.22 33.44                                > "$W/hit/public-ip"
printf 'cd /%s/%s/src\n' Users jdoe                                   > "$W/hit/home-path"
printf 'contact: %s@%s\n' jane.doe corp-mail.net                       > "$W/hit/email"

# placeholders and look-alikes that must not be reported
{
  echo "server 203.0.113.10, 198.51.100.7, 192.0.2.1, lan 10.1.2.3 192.168.1.1 172.20.0.5 127.0.0.1 169.254.1.1"
  echo "versions v1.2.3.4 go1.22.3.4 1.2.3.4.5 01.2.3.4, mask 255.255.255.0, any 0.0.0.0"
  echo "mail user@example.com ops@shop.example a@b.invalid noreply@github.com unit foo@bar.service"
  echo "paths /home/runner/work /Users/Shared /home/vmadmin /home/u ~/projects"
  echo 'password=$DB_PASSWORD token="${TOKEN}" secret=none password=changeme123 api_key=<your-key>'
  echo "aws AKIAIOSFODNN7EXAMPLE url https://u:p@x postgres://role:secret@host/db"
  echo "topic https://ntfy.sh/<topic>"
} > "$W/clean/placeholders"
: > "$W/allow.empty"

out=$("$SCAN" --allow "$W/allow.empty" "$W/hit" 2> "$W/err"); rc=$?
check "S1 a tree with findings exits 1 (rc=$rc)" test "$rc" = 1
for f in "$W"/hit/*; do
  k=${f##*/}
  check "S2 finds $k" eval 'printf "%s\n" "$out" | grep -q "hit/$k:[0-9]*: $k\$"'
done
leak=""
for f in "$W"/hit/*; do
  v=$(sed -n 's/.*[=:@ ]\([^ =:@]\{12,\}\).*/\1/p' "$f" | head -1)
  [ -n "$v" ] && printf '%s\n%s\n' "$out" "$(cat "$W/err")" | grep -qF -- "$v" && leak="$leak ${f##*/}"
done
check "S3 no value is printed${leak:+ (leaked:$leak)}" test -z "$leak"

out=$("$SCAN" --allow "$W/allow.empty" "$W/clean" 2>&1); rc=$?
check "S4 placeholders, private ranges and versions are not findings (rc=$rc)" test "$rc" = 0
[ "$rc" = 0 ] || printf '%s\n' "$out" | sed 's/^/  /'

printf '%s | email | @corp-mail\\.net$ | a fixture for this test\n' "$W/hit/*" > "$W/allow.one"
out=$("$SCAN" --allow "$W/allow.one" "$W/hit/email" 2>&1); rc=$?
check "S5 an allowlist entry silences exactly its match (rc=$rc)" test "$rc" = 0
printf '%s | email | .*\n' "$W/hit/*" > "$W/allow.bad"
"$SCAN" --allow "$W/allow.bad" "$W/hit/email" > /dev/null 2>&1; rc=$?
check "S6 an allowlist entry without a reason is refused (rc=$rc)" test "$rc" = 2

out=$("$SCAN" --allow "$W/allow.empty" "$SCAN" "$0" "$ROOT/scripts/secret-scan.allow" 2>&1); rc=$?
check "S7 the scanner, its allowlist and this test do not match themselves (rc=$rc)" test "$rc" = 0

echo "$n checks, $fails failed"
[ "$fails" = 0 ]
