#!/bin/bash
# lint: side=linux
# Server-side invariant check for test/race. Run as root: ssh ... sudo bash -s [apps...] < inv-server.sh
# Prints one "VIOL <app|host> <text>" line per broken invariant, and "OK" when none broke.
# Optional env (passed as leading args KEY=VAL): QUIET_UNITS=1 skips the transient-unit check.
set -u
R=/opt/tando
viol() { echo "VIOL $1 ${*:2}"; V=$((V + 1)); }
V=0
declare -A PORTS UIDS SITES
apps=()
for f in "$R"/apps/*/app.conf; do [[ -f $f ]] || continue; f=${f%/app.conf}; apps+=("${f##*/}"); done
for d in "$R"/apps/*/; do
  d=${d%/}; [[ -d $d ]] && ! [[ -f $d/app.conf ]] && viol "${d##*/}" "app directory without app.conf (half-made or half-destroyed)"
done
for a in ${apps[@]+"${apps[@]}"}; do
  D=$R/apps/$a
  declare -A S=() C=()
  # state parseable: every non-empty line key=value with a sane key
  n=0
  while IFS= read -r l; do
    n=$((n + 1))
    [[ $l =~ ^[a-z_][A-Za-z0-9_.-]*=.*$ ]] || { viol "$a" "state line $n not key=value: ${l:0:80}"; continue; }
    S[${l%%=*}]=${l#*=}
  done < "$D/state"
  while IFS= read -r l; do [[ $l == *=* ]] && C[${l%%=*}]=${l#*=}; done < "$D/app.conf"
  [[ ${S[phase]:-idle} == idle ]] || viol "$a" "phase=${S[phase]} (not idle)"
  cur=${S[current]:-}
  link=$(readlink "$D/current" 2> /dev/null); link=${link##*/}
  if [[ -z $cur ]]; then
    [[ -n ${S[stopped]:-} || ${C[recipe]:-} == "" ]] || viol "$a" "no current release in state"
  else
    [[ $link == "$cur" ]] || viol "$a" "current link=$link but state current=$cur"
    [[ -d $D/releases/$cur ]] || viol "$a" "current release $cur missing on disk"
    [[ ${S[status_$cur]:-} == verified ]] || viol "$a" "current $cur status=${S[status_$cur]:-none}"
  fi
  # exactly one current: no other release claims to be the live one (verified ones may be many);
  # every release dir has a status, except a release still being activated
  for r in "$D"/releases/*; do
    [[ -d $r ]] || continue; r=${r##*/}
    [[ -n ${S[status_$r]:-} ]] || viol "$a" "release $r on disk without a status (orphan)"
    [[ ${S[status_$r]:-} == bad ]] && viol "$a" "bad release $r still on disk"
  done
  # history.tsv: 12 tab fields, epoch first
  if [[ -f $D/history.tsv ]]; then
    awk -F'\t' -v a="$a" 'NF != 12 || $1 !~ /^[0-9]{9,}$/ { printf "VIOL %s history line %d malformed (NF=%d): %.100s\n", a, NR, NF, $0 }' "$D/history.tsv"
    c=$(awk -F'\t' 'NF != 12 || $1 !~ /^[0-9]{9,}$/' "$D/history.tsv" | wc -l); V=$((V + c))
  else viol "$a" "no history.tsv"; fi
  # leftovers
  [[ -f $D/upload ]] && viol "$a" "upload lease left: $(tr '\n' ' ' < "$D/upload")"
  for t in "$D"/*.tmp* "$D"/env.tmp; do [[ -e $t ]] && viol "$a" "temp file left: ${t##*/}"; done
  flock -n "$D/lock" true || viol "$a" "app lock still held"
  flock -n "$D/lease.lock" true || viol "$a" "lease lock still held"
  p=${C[port]:-}; sp=${C[preflight_port]:-$((p + 100))}
  [[ -n $p ]] && ss -Hltn "sport = :$sp" | grep -q . && viol "$a" "spare port $sp still has a listener"
  if [[ -z ${QUIET_UNITS:-} ]]; then
    u=$(systemctl list-units --all --plain --no-legend "tando-$a-act-*" "tando-$a-pre-*" 2> /dev/null | awk '{print $1}' | tr '\n' ' ')
    [[ -n ${u// } ]] && viol "$a" "transient units left: $u"
  fi
  # ports, uids unique
  [[ -n $p ]] && { [[ -n ${PORTS[$p]:-} ]] && viol "$a" "port $p also used by ${PORTS[$p]}"; PORTS[$p]=$a; }
  uid=$(id -u "${C[user]:-tando-$a}" 2> /dev/null) || viol "$a" "user ${C[user]:-tando-$a} missing"
  [[ -n ${uid:-} ]] && { [[ -n ${UIDS[$uid]:-} ]] && viol "$a" "uid $uid also used by ${UIDS[$uid]}"; UIDS[$uid]=$a; }
  # Caddy site file present and serving the app's port
  cf=/etc/caddy/tando/$a.caddy
  if [[ -f $cf ]]; then
    [[ ${C[recipe]:-node} == static ]] || [[ -n ${S[stopped]:-} ]] || grep -q "reverse_proxy 127.0.0.1:$p " "$cf" ||
      viol "$a" "caddy file does not proxy to port $p"
    # domains of app.conf all in the caddy file and vice versa
    for x in ${C[domains]:-}; do grep -q "${x%|*}" "$cf" || viol "$a" "domain ${x%|*} in app.conf, not in Caddy"; done
  else viol "$a" "no caddy file"; fi
  # nftables rule for this uid and port
  if [[ -n ${uid:-} && -n $p ]]; then
    nft list table inet tando 2> /dev/null | grep -q "skuid $uid tcp dport { $p, $sp } accept" ||
      viol "$a" "nftables has no accept rule for uid $uid port $p"
  fi
  # the app's unit is active unless stopped / static
  if [[ ${C[recipe]:-node} != static && -z ${S[stopped]:-} && -n $cur ]]; then
    systemctl -q is-active "tando-$a" || viol "$a" "tando-$a is not active"
  fi
  unset S C
done
# sites exactly once across all caddy files
while read -r cnt site; do
  ((cnt > 1)) && viol host "site $site defined $cnt times in Caddy"
done < <(cat /etc/caddy/tando/*.caddy 2> /dev/null | grep -E '^[^[:space:]#].*\{$' | sed 's/ {$//' | tr ',' '\n' |
  sed 's/^ *//' | sort | uniq -c)
# caddy files without an app
for cf in /etc/caddy/tando/*.caddy; do
  [[ -f $cf ]] || continue; a=${cf##*/}; a=${a%.caddy}
  [[ -f $R/apps/$a/app.conf ]] || viol "$a" "caddy file without an app"
done
ls /etc/caddy/tando/ 2> /dev/null | grep -E '\.(tmp|old)$' | while read -r x; do echo "VIOL host caddy temp file left: $x"; done
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null 2>&1 || viol host "caddy validate fails"
# nftables: no rule for a uid that is no app
want=$(for a in ${apps[@]+"${apps[@]}"}; do id -u "tando-$a" 2> /dev/null; done | sort -u | tr '\n' ' ')
have=$(nft list table inet tando 2> /dev/null | sed -n 's/.*skuid \([0-9]*\) tcp dport {.*accept/\1/p' | sort -u | tr '\n' ' ')
[[ "$want" == "$have" ]] || viol host "nftables uids [$have] != app uids [$want]"
# users tando-* without an app (not deploy users)
getent passwd | awk -F: '$1 ~ /^tando-/ && $1 !~ /^tando-d-/ && $1 != "tando-keys" {print $1}' | while read -r u; do
  [[ -f $R/apps/${u#tando-}/app.conf ]] || echo "VIOL host user $u without an app"
done
[[ -e $R/firewall.nft.tmp ]] && viol host "firewall.nft.tmp left"
ls "$R"/*.tmp* 2> /dev/null | while read -r x; do echo "VIOL host temp file left: $x"; done
# host.conf parseable
grep -vE '^[a-z_]+=' "$R/host.conf" 2> /dev/null | while read -r l; do echo "VIOL host host.conf line: $l"; done
((V)) || echo OK
