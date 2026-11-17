#!/bin/bash
# g3: history.tsv ends in a half-written line (crash or full disk while appending). Expect: the next
# deploy's line is intact and `tando history` shows it.
. "$(dirname "$0")/lib-fault.sh"
f_init g3 "history.tsv truncated mid-line" "deploy + history"
A=fg3; f_fresh $A
srv "sudo bash -c 'f=/opt/tando/apps/$A/history.tsv; s=\$(stat -c %s \$f); truncate -s \$((s - 20)) \$f'"
deploy $A 3 ok; ok "deploy works" test $DRC = 0
id=$(rid "$W/$A.d3.out")
"$R" history -a $A > "$W/h.out" 2>&1; cat "$W/h.out" >&2
ok "history shows release $id as its own row" sh -c "grep -E '^│ .*$id' '$W/h.out' | grep -q ' ok '"
srv "sudo tail -2 /opt/tando/apps/$A/history.tsv" | cat -A | cut -c1-160 >&2
truth $A 3
next_deploy $A 4
f_end
