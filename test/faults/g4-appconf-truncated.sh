#!/bin/bash
# g4: app.conf lost its last line (start= sorts last). Expect: deploy refuses or keeps v2 serving,
# with a message; status/doctor say what is wrong; `tando up` repairs it.
. "$(dirname "$0")/lib-fault.sh"
f_init g4 "app.conf truncated (last line lost)" "deploy"
A=fg4; f_fresh $A
srv "sudo bash -c 'f=/opt/tando/apps/$A/app.conf; tail -1 \$f; s=\$(stat -c %s \$f); l=\$(tail -1 \$f | wc -c); truncate -s \$((s - l + 3)) \$f'" >&2
"$R" doctor > "$W/doc0.out" 2>&1
grep -q "app $A" "$W/doc0.out" || log "doctor silent about the truncated app.conf"
loop_start $A
deploy $A 3 ok; log "deploy rc=$DRC: $(grep -E 'tando-agent|rolled|failed|pre-flight' "$W/$A.d3.out" | head -2 | tr '\n' ' ')"
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
v=$(ver $A); log "serving v$v"
truth $A "$v"
F_NOTES="$F_NOTES; next deploy uses tando up (it rewrites app.conf)"
setv $A 4 ok; (cd "$W/$A" && "$R" up > "$W/up.out" 2>&1) && serves $A 4 || { F_RECOVER=n; F_NOTES="$F_NOTES; tando up did not repair"; tail -4 "$W/up.out" >&2; }
f_end
