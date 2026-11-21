#!/bin/bash
# test/json-contract.sh: every `--json` of the CLI against its schema, without a server. Run by
# test/ui-test.sh (and on its own); bash 3.2 compatible; needs python3 (test/json-check.py).
#
#   test/json-contract.sh [--samples]     (--samples rewrites test/fixtures/json/<verb>.sample.json)
#
# A stub ssh (test/fixtures/json/ssh-stub) answers the agent with canned rows (invented data). Each
# verb's output must hold test/fixtures/json/<verb>.schema (one <key.path>:<type> per line; see
# test/json-check.py): a removed or retyped key fails, an added key passes. The samples (what a
# dashboard's own tests load) must hold the same schemas. Then the behaviour of tando snapshot
# (one ssh exec per host, gap-filled metrics, restart deltas, state_reason, deployer, timeouts),
# env ls --json (names via env-names, never env-ls) and the series of errors, requests and health.
# One line per check (PASS/FAIL/SKIP); the last line is "json: <n> checks, <m> failed".
# shellcheck disable=SC2034  # out, el: read by the eval'd checks
set -u
here=$(cd "$(dirname "$0")/.." && pwd -P)
R=$here
FX=$here/test/fixtures/json
T=$(mktemp -d "${TMPDIR:-/tmp}/json-contract.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
n=0 nf=0
ok() { n=$((n + 1)); echo "PASS json $1"; }
bad() { n=$((n + 1)); nf=$((nf + 1)); echo "FAIL json $1"; }
check() { local t=$1; shift; if "$@"; then ok "$t"; else bad "$t"; fi; }
finish() { echo "json: $n checks, $nf failed"; exit 0; }
if ! command -v python3 > /dev/null 2>&1; then echo "SKIP json python3 not found"; finish; fi
py() { python3 -I "$@"; }
JC=$here/test/json-check.py

export HOME=$T/home TANDO_CONFIG_DIR=$T/cfg NO_COLOR=1 TANDO_NO_BROWSER=1 STUB_LOG=$T/log
mkdir -p "$HOME" "$TANDO_CONFIG_DIR/hosts" "$T/bin" "$T/out" "$T/work"
cp "$FX/ssh-stub" "$T/bin/ssh" && chmod +x "$T/bin/ssh"
host() { printf 'target=nobody@%s\nport=22\nkey=\ninsecure=1\nkind=admin\n' "$2" > "$TANDO_CONFIG_DIR/hosts/$1"; }
host web-1 192.0.2.10
tando() { (cd "$T/work" && PATH=$T/bin:$PATH "$R/bin/tando" "$@"); }

# ---- the checker itself: a removed or retyped key fails, an added one passes ----------------------
printf '{"a":1,"b":[{"c":"x","d":null}]}' > "$T/j1"
printf 'a:number\nb[].c:string\nb[].d:null-or-number\n' > "$T/s1"
check "J1 the checker passes a document that holds its schema" py "$JC" check "$T/s1" "$T/j1"
printf '{"a":1,"b":[{"c":"x","d":null,"e":true}],"f":2}' > "$T/j2"
check "J2 an added key passes" py "$JC" check "$T/s1" "$T/j2"
printf '{"a":1,"b":[{"d":null}]}' > "$T/j3"
check "J3 a removed key fails" eval '! py "$JC" check "$T/s1" "$T/j3" > /dev/null'
printf '{"a":"1","b":[{"c":"x","d":null}]}' > "$T/j4"
check "J4 a retyped key fails" eval '! py "$JC" check "$T/s1" "$T/j4" > /dev/null'
printf '{"a":1,"b":[]}' > "$T/j5"
check "J5 an empty array the rules walk into fails (no vacuous pass)" eval '! py "$JC" check "$T/s1" "$T/j5" > /dev/null'

# ---- every --json against its schema -------------------------------------------------------------
# verb | arguments (one line each; the verb names the schema and the sample)
VERBS='ls|ls --json
ls-all|ls --all --json
ls-all-down|ls --all --json
status|status shop --json
history|history --json
releases|releases shop --json
snapshot|snapshot --json -H web-1
snapshot-app|snapshot --json -H web-1 --app shop --range 24h
snapshot-unreachable|snapshot --json -H web-2
env-ls|env ls shop --json
env-log|env log -a shop --json
jobs|jobs ls shop --json
backup-ls|backup ls shop --json
doctor|doctor --json
alerts|alerts --json
health|health --json
errors|errors shop --json
requests|requests -a shop --json
host-status|host status web-1 --json'
while IFS='|' read -r v args; do
  # web-2 is down (connection refused); a schema has one shape per array, so ls-all-down is the
  # list with that host alone
  host web-1 192.0.2.10; rm -f "$TANDO_CONFIG_DIR/hosts/web-2"
  case $v in snapshot-unreachable) host web-2 192.0.2.99;;
    ls-all-down) host web-2 192.0.2.99; rm -f "$TANDO_CONFIG_DIR/hosts/web-1";; esac
  # (the stub's clock is this one's here: the samples show a server in sync, a few seconds ahead)
  # shellcheck disable=SC2086  # the arguments, one word each
  STUB_T=$(date +%s) tando $args > "$T/out/$v.json" 2> "$T/out/$v.err"
  if [ ! -f "$FX/$v.schema" ]; then bad "C-$v no schema $FX/$v.schema"; continue; fi
  if py "$JC" check "$FX/$v.schema" "$T/out/$v.json" > "$T/out/$v.chk" 2>&1; then
    ok "C-$v tando $args holds $v.schema"
  else
    bad "C-$v tando $args holds $v.schema"; sed 's/^/    /' "$T/out/$v.chk" | head -12; sed 's/^/    stderr: /' "$T/out/$v.err" | head -4
  fi
  if [ "${1:-}" = --samples ]; then   # (indented: a reader diffs them)
    py -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "w"), indent=1); open(sys.argv[2], "a").write("\n")' \
      "$T/out/$v.json" "$FX/$v.sample.json"
  fi
  if [ -f "$FX/$v.sample.json" ]; then
    check "S-$v the dashboard's sample $v.sample.json holds $v.schema" py "$JC" check "$FX/$v.schema" "$FX/$v.sample.json"
  else bad "S-$v no sample $FX/$v.sample.json (test/json-contract.sh --samples writes them)"; fi
done << EOF
$VERBS
EOF
host web-1 192.0.2.10; rm -f "$TANDO_CONFIG_DIR/hosts/web-2"

# ---- tando snapshot: behaviour -------------------------------------------------------------------
q() { py -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$1"; }   # file, python test on d
SA=$T/out/snapshot-app.json SC=$T/out/snapshot.json
: > "$T/log"; tando snapshot --json -H web-1 --app shop --range 24h > "$SA" 2> /dev/null
check "N1 snapshot --app: one ssh exec for the host ($(grep -c . "$T/log") made)" test "$(grep -c . "$T/log")" = 1
: > "$T/log"; tando snapshot --json -H web-1 > "$SC" 2> /dev/null
check "N2 snapshot without --app: one exec, and it reads no releases, history, metrics, health or audit" \
  eval 'test "$(grep -c . "$T/log")" = 1 && ! grep -qE "@releases|tando-metrics|tando-watch|audit-read" "$T/log"'
check "N3 server_now is the server's clock (the clock row), clock_skew_s and the versions are there" \
  q "$SC" 'd["server_now"] == 1795000003 and isinstance(d["clock_skew_s"], int) and d["server_version"] == "0.2.2"'
check "N4 system: the three load averages, memory and disk used/total, cpus, uptime" \
  q "$SC" 'd["system"] == {"hostname": "web-1", "cpus": 2, "load_1": 0.42, "load_5": 0.37, "load_15": 0.30, "memory_used_bytes": 1024000000, "memory_total_bytes": 2048000000, "disk_used_bytes": 12000000000, "disk_total_bytes": 40000000000, "uptime_s": 864000}'
check "N5 state_reason: running, down (died, a down alert), static, stopped (tando stop), deploying" \
  q "$SC" '[(a["app"], a["state_reason"]) for a in d["apps"]] == [("shop","running"),("api","down"),("docs","static"),("jobs","stopped"),("fresh","deploying")]'
check "N6 alerts: firing and pending" q "$SC" '[(a["check"], a["state"]) for a in d["alerts"]] == [("down","firing"),("disk","pending")]'
check "N7 metrics 24h: 144 buckets of 600 s, every one present, the last one is now's" \
  q "$SA" 'len(d["app"]["metrics"]["series"]) == 144 and all(b["t"] - a["t"] == 600 for a, b in zip(d["app"]["metrics"]["series"], d["app"]["metrics"]["series"][1:])) and d["app"]["metrics"]["series"][-1]["t"] == 1795000003 // 600 * 600'
check "N8 metrics: null where no sample (the gap), never interpolated; data_since is the first sample" \
  q "$SA" '[p["memory_bytes"] for p in d["app"]["metrics"]["series"][-6:]] == [100000000, 101000000, None, 102000000, 103000000, 104857600] and d["app"]["metrics"]["data_since"] == (1795000003 // 600 - 5) * 600'
check "N9 restarts are per-bucket deltas clamped at 0 (a counter reset is 0, a gap null)" \
  q "$SA" '[p["restarts"] for p in d["app"]["metrics"]["series"][-6:]] == [0, 1, None, 0, 1, 0]'
check "N10 history has the deployer from the audit log's who (deploy, rollback; null when not found)" \
  q "$SA" '[h["deployer"] for h in d["app"]["history"]] == ["ci-bot", "alice", None]'
check "N10b app.origin: where it was last deployed from (the releases verb's origin row)" \
  q "$SA" 'd["app"]["origin"] == "alice@laptop:/src/shop"'
: > "$T/log"; TANDO_FROM=dashboard tando releases shop -H web-1 > /dev/null 2>&1
check "N10c TANDO_FROM=dashboard (tando-dash's writes) goes in front of sudo in the ssh command" grep -q "TANDO_FROM=dashboard sudo -n /opt/tando/bin/tando-agent releases shop" "$T/log"
: > "$T/log"; TANDO_FROM=dashboard2 tando releases shop -H web-1 > /dev/null 2>&1; TANDO_FROM= tando releases shop -H web-1 > /dev/null 2>&1
check "N10d any other TANDO_FROM, or none: not in the ssh command" eval '! grep -q TANDO_FROM "$T/log" && test "$(grep -c "tando-agent releases" "$T/log")" = 2'
check "N11 health: uptime, p95, 24 hourly probe points (null where none), incidents, database" \
  q "$SA" 'd["app"]["health"]["p95_ms"] == 85 and len(d["app"]["health"]["series"]["points"]) == 24 and d["app"]["health"]["series"]["points"][2]["avg_ms"] is None and d["app"]["health"]["incidents"][0]["check"] == "down" and d["app"]["database"]["connection_limit"] == 20'
for r in 1h:60:60 7d:168:3600; do
  tando snapshot --json -H web-1 --app shop --range "${r%%:*}" > "$T/r.json" 2> /dev/null
  b=${r##*:} p=${r#*:}; p=${p%%:*}
  check "N12 --range ${r%%:*}: $p points of $b s" q "$T/r.json" "d['app']['metrics']['points'] == $p and len(d['app']['metrics']['series']) == $p and d['app']['metrics']['bucket_s'] == $b"
done
host web-2 192.0.2.99; host web-3 192.0.2.98   # refused; hangs
: > "$T/log"; s0=$SECONDS
TANDO_SNAPSHOT_TIMEOUT=2 tando snapshot --json --all > "$T/all.json" 2> /dev/null
el=$((SECONDS - s0))
check "N13 --all: one JSON line per host, in parallel, one exec each ($(grep -c . "$T/log") for 3 hosts)" \
  eval 'test "$(grep -c . "$T/all.json")" = 3 && test "$(grep -c . "$T/log")" = 3'
check "N14 an unreachable host is reachable:false with the reason; one that hangs ends at the timeout (${el} s)" \
  eval 'test $el -le 5 && py -c "import json,sys
L=[json.loads(l) for l in open(sys.argv[1])]
assert [x[\"reachable\"] for x in L] == [True, False, False], L
assert L[1][\"error\"] == \"connection refused\" and L[2][\"error\"] == \"no answer\"" "$T/all.json"'
check "N15 a hung host's ssh is not left running" eval '! pgrep -f "sleep 60" > /dev/null || ! ps -o command= -p $(pgrep -f "sleep 60" | head -1) | grep -q .'
rm -f "$TANDO_CONFIG_DIR/hosts/web-2" "$TANDO_CONFIG_DIR/hosts/web-3"
out=$(tando snapshot --json --all --app shop 2>&1); check "N16 --app goes with one host: --all --app is refused" eval 'printf "%s" "$out" | grep -q "goes with one host"'

# ---- names only, and the series ------------------------------------------------------------------
: > "$T/log"; tando env ls shop --json > "$T/env.json" 2> /dev/null
check "E1 env ls --json lists names through env-names, never env-ls (values never leave the server)" \
  eval 'grep -q "tando-agent env-names shop" "$T/log" && ! grep -q "env-ls" "$T/log" && q "$T/env.json" "d[\"names\"] == [\"DATABASE_URL\", \"SESSION_SECRET\", \"PUBLIC_BASE_URL\"]"'
: > "$T/log"; tando env ls shop --names > /dev/null 2>&1
check "E2 env ls --names: names only, through env-names" eval 'grep -q "env-names" "$T/log" && ! grep -q "env-ls" "$T/log"'
now=$(date +%s)
STUB_T=$now tando errors shop --json > "$T/er.json" 2> /dev/null
check "E3 errors --json: a series per group, one point per hour of the window, its counts from the server" \
  q "$T/er.json" "len(d['errors'][0]['series']) in (24, 25) and sum(p['count'] for p in d['errors'][0]['series']) == 3 and sum(p['count'] for p in d['errors'][1]['series']) == 1 and all(b['t'] - a['t'] == 3600 for a, b in zip(d['errors'][0]['series'], d['errors'][0]['series'][1:]))"
check "E4 requests --json: a series point per bucket (requests, 5xx), the class totals" \
  q "$T/out/requests.json" 'len(d["series"]) == 15 and sum(p["c5xx"] for p in d["series"]) == 5 and d["series"][1]["t"] - d["series"][0]["t"] == 60 and d["status_classes"]["4xx"] == 10'
check "E5 alerts --json: the recent history, newest first" \
  q "$T/out/alerts.json" '[h["event"] for h in d["history"]] == ["fire", "resolve", "fire"]'
check "E6 health --json: 24 hourly probe points per app" q "$T/out/health.json" 'len(d["apps"][0]["series"]) == 24 and d["apps"][0]["series"][2]["avg_ms"] is None'
e7() { tando doctor --json > /dev/null 2>&1; test $? = 1 && q "$T/out/doctor.json" "d['failed'] == 1 and d['warnings'] == 1"; }
check "E7 doctor --json: every check, the counts, exit 1 with a failure" e7
e8() {
  q "$T/out/ls.json" "d['apps'][1]['state_reason'] == 'down' and d['system']['cpus'] == 2" &&
    q "$T/out/status.json" "d['app']['state_reason'] == 'running'"
}
check "E8 ls and status --json carry state_reason and the system object" e8
finish
