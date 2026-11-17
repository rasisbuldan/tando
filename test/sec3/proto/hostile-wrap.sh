#!/bin/bash
# hostile-wrap: installed over /opt/tando/bin/<tool> on a TEST server only (the real one is <tool>.real).
# For verbs listed in /opt/tando/hostile/verbs it runs the real tool, then rewrites every field of its
# output into malicious variants (arithmetic injection, terminal escapes, odd numbers, huge values).
# /opt/tando/hostile/fixed/<tool>.<verb>: send that file verbatim instead.
self=${0##*/} real=$0.real H=/opt/tando/hostile v=${1:-}
[ -f "$H/fixed/$self.$v" ] && { cat "$H/fixed/$self.$v"; exit 0; }
grep -qx "$self.$v" "$H/verbs" 2> /dev/null || exec "$real" "$@"
M=${HOSTILE_MARK:-$(cat $H/mark 2>/dev/null)}
payloads() { # tag
  printf '%s\n' "x[\$(touch\${IFS}$M-$1)]" "\$(touch\${IFS}$M-c$1)" "\`touch\${IFS}$M-b$1\`" \
    $'\e]52;c;cHduZWQ=\a\e]0;PWNTITLE\a' $'\xc2\x9b2J\x9b2J\e[2J' "99999999999999999999999" "-5" "08" "1e9" \
    "x$(head -c 3000 /dev/zero | tr '\0' A)" "../../../../tmp/evil" "-oProxyCommand=touch\${IFS}$M-o$1"
}
out=$("$real" "$@" 2>/dev/null); rc=$?
mapfile -t P < <(payloads "$self.$v")
n=0
while IFS= read -r line; do
  printf '%s\n' "$line"
  if [[ $line == *$'\t'* ]]; then
    IFS=$'\t' read -r -a f <<< "$line"
    for ((k = 1; k < ${#f[@]}; k++)); do
      for p in "${P[@]}"; do
        g=("${f[@]}"); g[k]=${p//$M-/$M-$k-}; n=$((n+1)); ((n > ${HOSTILE_MAX:-4000})) && break 3
        (IFS=$'\t'; printf '%s\n' "${g[*]}")
      done
    done
  elif [[ $line == *=* ]]; then
    for p in "${P[@]}"; do printf '%s=%s\n' "${line%%=*}" "${p//$M-/$M-${line%%=*}-}"; done
  fi
done <<< "$out"
exit $rc
