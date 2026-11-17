#!/bin/bash
# scripts/secret-scan.sh: refuse credentials and private details in what git would commit.
#
#   scripts/secret-scan.sh              every file git would commit (tracked + untracked, not ignored)
#   scripts/secret-scan.sh --staged     the staged version of each staged file (the pre-commit hook)
#   scripts/secret-scan.sh PATH...      these files, or every file under these directories
#   --allow FILE                        allowlist (default scripts/secret-scan.allow)
#   --kinds                             list what is detected and exit
#
# A finding prints "file:line: kind" and never the value. Exit 0 clean, 1 findings, 2 usage error.
# Binary files are skipped. Needs only bash 3.2, grep -E and awk (no intervals in awk regexes).
#
# Kinds:
#   private-key     a PEM/OpenSSH/PGP private key block header, or a PuTTY key file
#   aws-key-id      an AWS-style access key id (AKIA/ASIA + 16)
#   access-secret   access_key / secret_key / key_id / account_key = <20+ chars> (AWS, R2, S3)
#   github-token    ghp_ gho_ ghu_ ghs_ ghr_ and github_pat_ tokens
#   slack-token     xoxa/xoxb/xoxp/xoxo/xoxr/xoxs tokens
#   webhook-url     Slack and Discord webhook URLs (the path is the secret)
#   ntfy            ntfy access tokens (tk_...) and ntfy.sh topic URLs (the topic is the secret)
#   url-credentials scheme://user:password@host (not localhost, example or .invalid hosts)
#   token-param     ?token= &key= &secret= &sig= ... with a 16+ character value
#   password        password= secret= token= api_key= ... with a literal, non-placeholder value
#                   (8+ characters with a letter and a digit; a backslash escape ends the value)
#   recovery-key    a tando offsite recovery key (tando-key- and 14 groups of 4)
#   public-ip       an IPv4 address outside 10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, 0/8,
#                   192.0.2/24, 198.51.100/24, 203.0.113/24 and 224/3; version-like strings (a
#                   letter right before, a leading zero, more than four parts) are not addresses
#   home-path       /Users/<name> or /home/<name>, except generic names: one or two characters,
#                   placeholders (me you user username name example alice bob charlie),
#                   CI and test accounts (runner vmadmin dev deploy ubuntu admin), service
#                   accounts (git www-data dokku kamal-proxy tando app) and /Users/Shared
#   email           name@domain.tld, except at example.com/.org/.net, *.example, *.invalid,
#                   *.test, *.localhost, noreply/no-reply addresses, and unit or file names
#                   (foo@bar.service, x@y.conf)
#
# Placeholders are not findings: values with example, placeholder, changeme, dummy, fake, redacted,
# xxxx, your, sample, test, secret, <...>, ${...} or $VAR; URL passwords of 4 characters or less.
#
# Allowlist (scripts/secret-scan.allow), one entry per line, four fields separated by " | ":
#   path glob | kind or * | ERE matched against the found text | reason (required)
# e.g.  srv/foo/testdata/* | email | @lists\.example\.org$ | public package maintainers
# Globs are shell-like (* also matches /). Write EREs without {n} intervals.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
allow=$ROOT/scripts/secret-scan.allow staged=0
paths=()
while [ $# -gt 0 ]; do
  case $1 in
    --staged) staged=1;;
    --allow) allow=${2:?--allow needs a file}; shift;;
    --kinds) sed -n '/^# Kinds:/,/^# Placeholders/p' "$0" | sed '1d; $d; s/^#   //'; exit 0;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    --) shift; paths+=("$@"); break;;
    -*) echo "secret-scan: unknown option $1" >&2; exit 2;;
    *) paths+=("$1");;
  esac
  shift
done
[ -f "$allow" ] || { echo "secret-scan: no allowlist $allow" >&2; exit 2; }
case $allow in /*) ;; *) allow=$PWD/$allow;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/secret-scan.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

# the file list, NUL-separated, relative to the directory we scan from
if [ ${#paths[@]} -gt 0 ]; then
  for p in ${paths[@]+"${paths[@]}"}; do
    [ -e "$p" ] || { echo "secret-scan: no such file: $p" >&2; exit 2; }
    find "$p" -name .git -prune -o -type f -print0
  done > "$tmp/list"
elif [ "$staged" = 1 ]; then
  cd "$ROOT" || exit 2
  git diff --cached --name-only -z --diff-filter=ACMR > "$tmp/list" || exit 2
  # scan what will be committed, not what is in the working tree
  mkdir "$tmp/idx" && git checkout-index -z --prefix="$tmp/idx/" --stdin < "$tmp/list" || exit 2
  cd "$tmp/idx" || exit 2
else
  cd "$ROOT" || exit 2
  git ls-files -co --exclude-standard -z > "$tmp/all" || exit 2
  # tracked files deleted from the working tree are listed too: keep the ones that exist
  while IFS= read -r -d '' f; do [ -f "$f" ] && printf '%s\0' "$f"; done < "$tmp/all" > "$tmp/list"
fi
nfiles=$(tr -cd '\0' < "$tmp/list" | wc -c | tr -d ' ')

# The patterns are written so that this file does not match itself.
KINDS=(
  'private-key|-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----|PuTTY-User-Key-File-[0-9]+:'
  'aws-key-id|(AKIA|ASIA)[A-Z0-9]{16}'
  'access-secret|i|(secret_?access_?key|secret_?key|access_?key(_?id)?|key_?id|account_?key|aws_?secret|r2_?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+=_.-]{20,}'
  'github-token|(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})'
  'slack-token|xox[abposr]-[A-Za-z0-9-]{10,}'
  'webhook-url|hooks\.slack\.com/services/[A-Za-z0-9_/-]{20,}|discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]{20,}'
  'ntfy|tk_[a-z0-9]{29}|ntfy\.sh/[A-Za-z0-9_-]{10,}'
  'url-credentials|[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]:@"'"'"'<>]+:[^/[:space:]@"'"'"'<>]+@[A-Za-z0-9.-]+'
  'token-param|i|[?&](token|access_token|auth|key|secret|sig|signature|apikey|api_key)=[A-Za-z0-9._~%-]{16,}'
  'password|i|(password|passwd|passphrase|secret|token|api_?key|auth_?token)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]"'"'"'`;,)]{8,}'
  'recovery-key|tando-key-[a-z2-7]{4}(-[a-z2-7]{4}){13}'
  'public-ip|[A-Za-z_]?[0-9]+(\.[0-9]+){3,}[A-Za-z]?'
  'home-path|/(Users|home)/[A-Za-z0-9._-]+'
  'email|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
)

: > "$tmp/hits"
if [ "$nfiles" -gt 0 ]; then
  for k in "${KINDS[@]}"; do
    name=${k%%|*} pat=${k#*|} ci=""
    case $pat in i\|*) ci=-i pat=${pat#i|};; esac
    # file NUL line:match  ->  kind TAB file TAB line:match
    # lint: allow RL02 --null is in both GNU and BSD grep (-Z is not: on BSD it means zgrep)
    xargs -0 grep -IHno $ci --null -E -e "$pat" -- < "$tmp/list" 2> /dev/null |
      tr '\0' '\t' | sed "s/^/$name	/" >> "$tmp/hits"
  done
fi

awk -F'\t' -v allowf="$allow" '
function lower(s) { return tolower(s) }
function placeholder(v,  l) {
  l = lower(v)
  if (l ~ /example|placeholder|changeme|change-me|dummy|fake|redacted|xxxx|your|sample|test|secret|<|>|\$|\.\.\.|\*\*\*/) return 1
  return 0
}
# the value of "name = value" / "name: value", unquoted
function value(t,  i) {
  i = match(t, /[:=]/); t = substr(t, i + 1)
  gsub(/^[[:space:]"'\'']+|["'\'']+$/, "", t)
  sub(/\\.*$/, "", t)                                  # "token=x\nnext=1": an escape ends it
  return t
}
function octet_ok(o) { return o ~ /^(0|[1-9][0-9]*)$/ && o + 0 <= 255 }
function public_ip(t,  n, p, a, b) {
  if (t ~ /^[A-Za-z_]/ || t ~ /[A-Za-z]$/) return 0        # v1.2.3.4, go1.2.3.4: versions
  n = split(t, p, ".")
  if (n != 4) return 0
  if (!octet_ok(p[1]) || !octet_ok(p[2]) || !octet_ok(p[3]) || !octet_ok(p[4])) return 0
  a = p[1] + 0; b = p[2] + 0
  if (a == 0 || a == 10 || a == 127 || a >= 224) return 0
  if (a == 172 && b >= 16 && b <= 31) return 0
  if (a == 192 && b == 168) return 0
  if (a == 169 && b == 254) return 0
  if (a == 192 && b == 0 && p[3] == "2") return 0
  if (a == 198 && b == 51 && p[3] == "100") return 0
  if (a == 203 && b == 0 && p[3] == "113") return 0
  return 1
}
function home_private(t,  n) {
  n = t; sub(/^\/(Users|home)\//, "", n)
  if (length(n) <= 2 || n ~ /^\./) return 0
  if (n ~ /^(me|you|user|username|name|example|alice|bob|charlie|runner|vmadmin|dev|deploy|ubuntu|admin|git|www-data|dokku|kamal-proxy|tando|app|Shared)$/) return 0
  return 1
}
function email_private(t,  d, l) {
  l = lower(t); d = l; sub(/^.*@/, "", d)
  if (d ~ /\.(service|conf|timer|socket|target|mount|path|slice|scope|swap|device|sh|json|txt|md|log|go|js|ts|py|yml|yaml|toml|lock|gz|deb|rb|png|svg)$/) return 0
  if (d ~ /(^|\.)example\.(com|org|net)$|\.example$|\.invalid$|\.test$|\.localhost$|^localhost$|\.tld$/) return 0
  if (l ~ /^(noreply|no-reply)@|@users\.noreply\./) return 0
  return 1
}
function credentials_private(t,  h, pw) {
  h = t; sub(/^.*@/, "", h)
  if (h ~ /^(localhost|127\.|example|.*\.example|.*\.invalid$|.*\.test$|.*\.localhost$)/) return 0
  pw = t; sub(/^[^:]*:\/\/[^:]*:/, "", pw); sub(/@.*$/, "", pw)
  if (length(pw) <= 4 || lower(pw) ~ /^(password|passwd|pass|pwd)$/) return 0
  return !placeholder(pw)
}
function finding(kind, t,  v) {
  if (kind == "public-ip") return public_ip(t)
  if (kind == "home-path") return home_private(t)
  if (kind == "email") return email_private(t)
  if (kind == "url-credentials") return credentials_private(t)
  if (kind == "aws-key-id") return t !~ /EXAMPLE/
  if (kind == "ntfy") { v = t; sub(/^ntfy\.sh\//, "", v); return !placeholder(v) && v !~ /^(topic|mytopic|my-)/ }
  if (kind == "token-param") { v = t; sub(/^[^=]*=/, "", v); return !placeholder(v) }
  if (kind == "access-secret" || kind == "password") {
    v = value(t)
    if (placeholder(v)) return 0
    if (v ~ /^[-%{(\[`@]/) return 0                       # code, not a literal
    if (v !~ /[0-9]/ || v !~ /[A-Za-z]/) return 0         # a word or a number, not a secret
    return length(v) >= 8
  }
  return 1
}
function glob_re(g) {
  gsub(/[.+(){}|^$\\[\]]/, "\\\\&", g)
  gsub(/\*/, ".*", g); gsub(/\?/, ".", g)
  return "^" g "$"
}
BEGIN {
  FS = "\t"
  while ((getline l < allowf) > 0) {
    if (l ~ /^[[:space:]]*(#|$)/) continue
    n = split(l, f, / \| /)
    if (n != 4 || f[4] ~ /^[[:space:]]*$/) { printf "secret-scan: %s: bad allowlist line (need path | kind | regex | reason): %s\n", allowf, l > "/dev/stderr"; bad = 1; continue }
    na++; ap[na] = glob_re(f[1]); ak[na] = f[2]; ar[na] = f[3]
  }
  if (bad) exit 2
}
{
  kind = $1; file = $2; rest = $3
  for (i = 4; i <= NF; i++) rest = rest "\t" $i
  c = index(rest, ":"); line = substr(rest, 1, c - 1); tok = substr(rest, c + 1)
  if (!finding(kind, tok)) next
  for (i = 1; i <= na; i++)
    if ((ak[i] == "*" || ak[i] == kind) && file ~ ap[i] && tok ~ ar[i]) next
  key = file ":" line ": " kind
  if (!(key in seen)) { seen[key] = 1; print key }
}
END { if (bad) exit 2 }
' "$tmp/hits" > "$tmp/out"
rc=$?
[ "$rc" = 0 ] || exit 2
sed 's|^\./||' "$tmp/out" | LC_ALL=C sort -t: -k1,1 -k2,2n > "$tmp/sorted"
n=$(wc -l < "$tmp/sorted" | tr -d ' ')
if [ "$n" -gt 0 ]; then
  cat "$tmp/sorted"
  echo "secret-scan: $n finding(s) in $(cut -d: -f1 < "$tmp/sorted" | sort -u | wc -l | tr -d ' ') file(s) of $nfiles." \
    "Remove the value, use a placeholder (203.0.113.10, user@example.com, ~/...), or allowlist a" \
    "deliberate fixture in scripts/secret-scan.allow with a reason." >&2
  exit 1
fi
echo "secret-scan: $nfiles files, no findings"
