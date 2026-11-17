#!/bin/bash
# s6-timing.sh <mode> <iterations>
#   soak:   deploy A ships a release that crashes 3 s after start (soak 8 s, so the soak rolls it
#           back); deploy B starts during A's soak window. The final live release must be verified
#           and must not be A's crashing one; B, if it reported live, must be what is served.
#   expire: deploy A uploads a large file; while it uploads, its lease is aged to just under / over
#           UPLOAD_TIMEOUT (900 s; test-only edit of `started` in the lease file); deploy B (laptop B,
#           another `who`) begins then. A mixed release or a success for both is a violation.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
MODE=$1 IT=${2:-10} APP=${3:-tm}
race_init "s6-timing-$MODE"
pa=$(mkproj A "$APP" 1); pb=$(mkproj B "$APP" 1)
# test app: crash N seconds after start when the release has a file "crash-after"
for p in "$pa" "$pb"; do
  grep -q crash-after "$p/server.js" || cat >> "$p/server.js" <<'JS'
if (fs.existsSync(__dirname + '/crash-after')) {
  const s = Number(fs.readFileSync(__dirname + '/crash-after', 'utf8'));
  if (port < 4200) setTimeout(() => process.exit(3), s * 1000);   // not in the pre-flight (+100)
}
JS
  grep -q '^soak' "$p/tando.conf" || echo "soak = 8" >> "$p/tando.conf"
done
rm -f "$pa/crash-after" "$pb/crash-after"
(cd "$pa" && rA up --force --yes > "$LOG/init.out" 2>&1) || { cat "$LOG/init.out"; exit 1; }
for i in $(seq 1 "$IT"); do
  setv A "$APP" "$i.1"; echo "$i.1" > "$pa/marker"; setv B "$APP" "$i.2"; echo "$i.2" > "$pb/marker"
  case $MODE in
    soak)
      echo 3 > "$pa/crash-after"
      ( cd "$pa" && rA deploy --force --yes > "$LOG/$i.a.out" 2>&1; echo $? > "$LOG/$i.a.rc" ) &
      # B begins somewhere in A's soak window (switch at ~1-2 s, crash at +3 s, soak ends at +8 s)
      ( sleep 1; jitter 6000; cd "$pb" && rB deploy --force --yes > "$LOG/$i.b.out" 2>&1; echo $? > "$LOG/$i.b.rc" ) &
      wait; rm -f "$pa/crash-after";;
    expire)
      # many small changed files: A's rsync writes into incoming/ for several seconds
      mkdir -p "$pa/many"; rm -rf "${pb:?}/many" "${pb:?}/blob.bin" "${pa:?}/blob.bin"
      perl -e 'for $i (1..12000) { open F, ">", "$ARGV[0]/many/f$i" or die; print F "$ARGV[1] $i\n" x 20; close F }' "$pa" "$i"
      ( cd "$pa" && rA deploy --force --yes > "$LOG/$i.a.out" 2>&1; echo $? > "$LOG/$i.a.rc" ) &
      ( for t in $(seq 1 50); do srv "sudo test -f /opt/tando/apps/$APP/upload" && break; sleep 0.1; done
        age=$(( 899 + RANDOM % 3 ))
        srv "sudo sed -i 's/^started=.*/started='\$((\$(date +%s) - $age))'/' /opt/tando/apps/$APP/upload"
        jitter 1500; cd "$pb" && rB deploy --force --yes > "$LOG/$i.b.out" 2>&1; echo $? > "$LOG/$i.b.rc" ) &
      wait;;
  esac
  settle "$APP"
  set -- $(srv "sudo cat /opt/tando/apps/$APP/current/VERSION /opt/tando/apps/$APP/current/marker /opt/tando/apps/$APP/current/crash-after 2> /dev/null" | tr '\n' ' ')
  [ "${1:-x}" = "${2:-y}" ] || { echo "[$T_SUITE $i] VIOL mixed release live: VERSION=${1:-} marker=${2:-}" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }
  [ -n "${3:-}" ] && { echo "[$T_SUITE $i] VIOL the crashing release (v${1:-}) is current after the round" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }
  ok=""; [ "$(cat "$LOG/$i.b.rc")" = 0 ] && ok="$i.2"
  [ "$MODE" = expire ] && [ "$(cat "$LOG/$i.a.rc")" = 0 ] && ok="$ok $i.1"
  exp=${ok# }; [ -n "$exp" ] || exp='*'
  [ "$MODE" = soak ] && [ "$(cat "$LOG/$i.a.rc")" = 0 ] && grep -q 'rolled back\|rollback' "$LOG/$i.a.out" || true
  for s in a b; do bad_output "$LOG/$i.$s.out" > /dev/null && { echo "[$T_SUITE $i] VIOL shell error in $s: $(bad_output "$LOG/$i.$s.out" | head -1)" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }; done
  inv "$i" "$APP" "$exp" || true
  echo "round $i: a=$(cat "$LOG/$i.a.rc") b=$(cat "$LOG/$i.b.rc") live=${1:-} v=$RACE_V" >&2
done
race_result "$T_SUITE" "$IT"
