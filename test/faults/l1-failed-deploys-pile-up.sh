#!/bin/bash
# l1: ten deploys in a row fail their pre-flight (a broken build retried, e.g. by CI). Each one copies
# a full release. Expect: failed releases are pruned like the others (at most KEEP=5 + current +
# last good kept), so repeated failures cannot fill the disk.
. "$(dirname "$0")/lib-fault.sh"
f_init l1 "10 failed deploys in a row" "preflight failures (prune)"
A=fl1; f_fresh $A
head -c 2000000 /dev/urandom > "$W/$A/blob.bin"
for v in 3 4 5 6 7 8 9 10 11 12; do deploy $A $v exit; done
n=$(srv "sudo ls /opt/tando/apps/$A/releases | wc -l"); du=$(srv "sudo du -sh /opt/tando/apps/$A/releases | cut -f1")
log "releases on disk after 10 failed deploys: $n ($du)"
ok "failed releases are pruned (<= 7 kept, found $n)" test "$n" -le 7
truth $A 2
next_deploy $A 13
n=$(srv "sudo ls /opt/tando/apps/$A/releases | wc -l"); log "after one good deploy: $n releases"
f_end
