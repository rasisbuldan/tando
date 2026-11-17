#!/bin/bash
# CPU hog app vs a neighbour: hello's latency at 200 rps (loadgen, 20 s) with no hog, with the hog
# app unlimited, and with `cpu = <limit>` in the hog's tando.conf. usage: cpu-neighbour.sh <hog-dir> <limit> <out>
set -u
. "$(dirname "$0")/lib.sh"
dir=$1 lim=$2 out=$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
m() { docker exec "$GEN" bash -c "node /root/loadgen.js http://127.0.0.1/ hello.localhost 200 2000 20 ka" | awk -F'\t' '/^[0-9]/{s+=$2;o+=$3; if($6!="-"&&$6>p)p=$6; if($7!="-"&&$7>q)q=$7} END{printf "sent=%d ok=%d worst_sec_p50_ms=%s worst_sec_p99_ms=%s", s,o,p,q}'; }
hcpu() { sx "c=\$(systemctl show -P ControlGroup tando-hog); [ -n \"\$c\" ] && sed -n 's/^usage_usec //p' /sys/fs/cgroup\$c/cpu.stat || echo 0"; }
docker cp "$LROOT/test/load/loadgen.js" "$GEN:/root/loadgen.js"
echo "no hog: $(m)" | tee -a "$out"
cd "$dir" || exit 1
sed -i '' '/^cpu =/d' tando.conf; TANDO_SOAK=2 "$R" up > /dev/null 2>&1
a=$(hcpu); r=$(m); b=$(hcpu); echo "hog unlimited: $r hog_cpu_s=$(( (b - a) / 1000000 ))/~20s" | tee -a "$out"
echo "cpu = $lim" >> tando.conf; TANDO_SOAK=2 "$R" up > /dev/null 2>&1
a=$(hcpu); r=$(m); b=$(hcpu); echo "hog cpu=$lim: $r hog_cpu_s=$(( (b - a) / 1000000 ))/~20s" | tee -a "$out"
"$R" stop -a hog > /dev/null 2>&1
