#!/bin/bash
# n3: two deploys of one app by the same user on the same machine (two terminals, two checkouts)
# while the first one uploads. Expect: the second is refused at once ("from this machine ...
# uploading now"), the first goes live with all of its own files (never a mix of the two
# uploads), and the next deploy works.
. "$(dirname "$0")/lib-fault.sh"
f_init n3 "second deploy of the same user during an upload" "upload"
A=fn3; f_fresh $A
f_big; cp "$FW/big/blob.bin" "$W/$A/"; echo 3 > "$W/$A/marker"
mkdir -p "$W/b"; cp -R "$W/$A" "$W/b/"; rm -f "$W/b/$A/blob.bin"; echo 9 > "$W/b/$A/marker"; echo 9 > "$W/b/$A/VERSION"
loop_start $A
setv $A 3 ok; client_bg $A deploy
wait_rsync; ok "upload running" test $? = 0
(cd "$W/b/$A" && "$R" deploy --force > "$W/second.out" 2>&1); rc=$?
log "second deploy: rc=$rc: $(grep tando: "$W/second.out" | tr '\n' ' ')"
ok "the second deploy is refused (rc=$rc)" test "$rc" != 0
ok "and says another deploy from this machine is uploading" grep -q 'from this machine.*uploading now' "$W/second.out"
client_wait 120; ok "the first deploy ends" test $? = 0
ok "the first deploy went live (rc=$(client_rc))" test "$(client_rc)" = 0
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
ok "the live release is all the first upload's (VERSION and marker 3)" \
  test "$(srv "sudo cat /opt/tando/apps/$A/current/VERSION /opt/tando/apps/$A/current/marker" | tr '\n' ' ')" = "3 3 "
truth $A 3
# (the refused deploy recorded its checkout as the origin: --force deploys from the first again)
rm -f "$W/$A/blob.bin"; setv $A 4 ok
(cd "$W/$A" && "$R" deploy --force > "$W/next.out" 2>&1); rc=$?
ok "the next deploy works (rc=$rc)" sh -c "[ $rc = 0 ] && [ \"\$(curl -s -m 5 $(url $A))\" = v4 ]"
f_end
