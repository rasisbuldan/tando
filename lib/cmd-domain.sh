# lib/cmd-domain.sh: `tando domain add|rm|ls`, an app on its own domain with HTTPS. bash 3.2.
#
# add checks DNS first, here on the laptop: every A/AAAA record of the domain (and of its www twin
# when that is served or redirected) must be one of the server's addresses; otherwise it prints
# the records to create and stops (--force goes on anyway, --wait polls until DNS is right). Then
# the server adds the name to the app's Caddy site (validated; rolled back if Caddy rejects it),
# and waits until the domain answers with a valid certificate, or reports Caddy's error.
# TANDO_TEST_RESOLVE="name=addr[+addr],..." replaces DNS (tests only).

# dns_lookup name: its addresses, one per line (A and AAAA)
dns_lookup() {
  if [ -n "${TANDO_TEST_RESOLVE:-}" ]; then
    printf '%s\n' "$TANDO_TEST_RESOLVE" | tr ',' '\n' | awk -F= -v n="$1" '$1 == n { print $2 }' | tr '+' '\n' | grep .
    return 0
  fi
  perl -MSocket=:addrinfo,SOCK_STREAM -e '
    my ($e, @r) = getaddrinfo($ARGV[0], "", { socktype => SOCK_STREAM }); exit 0 if $e;
    my %s; for (@r) { my ($e2, $h) = getnameinfo($_->{addr}, NI_NUMERICHOST, NIx_NOSERV); print "$h\n" unless $s{$h}++ }' "$1" 2> /dev/null
}

# server_addrs: the server's addresses (its global ones and the one tando reaches it at) -> SRV_ADDRS,
# and the one to put in a DNS record -> SRV_IP
server_addrs() {
  local t=${TARGET#*@} tip
  agent info < /dev/null > "$TMPD/info"
  kv_read "$TMPD/info" addrs ip domain_tls
  case $t in *[!0-9.]*) tip=$(dns_lookup "$t" | head -1);; *) tip=$t;; esac
  SRV_ADDRS=" $K_addrs $tip "
  SRV_IP=$(public_ip "$tip") || SRV_IP=${K_ip:-$tip}
  DOMAIN_TLS=$K_domain_tls
}

# dns_ok name: every address of name is the server's -> 0; else prints why to $TMPD/dns
dns_ok() {
  local a got
  got=$(dns_lookup "$1")
  if [ -z "$got" ]; then printf '  A     %-28s  ->  %s\n' "$1" "$SRV_IP" >> "$TMPD/dns"; return 1; fi
  for a in $got; do
    case $SRV_ADDRS in *" $a "*) ;; *)
      case $a in
        *:*) printf '  AAAA  %-28s  ->  remove it (it points at %s, not at this server)\n' "$1" "$a" >> "$TMPD/dns";;
        *) printf '  A     %-28s  ->  %s   (now %s)\n' "$1" "$SRV_IP" "$a" >> "$TMPD/dns";;
      esac
      return 1;;
    esac
  done
  return 0
}

# domain_dns domain www: checks the domain and its twin; with --wait polls until right
domain_dns() {
  local d=$1 w=$2 i=0 twin=""
  case $w in off) ;; *) case $d in www.*) twin=${d#www.};; *) twin=www.$d;; esac;; esac
  while :; do
    : > "$TMPD/dns"
    dns_ok "$d"; [ -n "$twin" ] && dns_ok "$twin"
    [ -s "$TMPD/dns" ] || return 0
    if [ -z "${DNS_WAIT:-}" ] || [ $i -ge 180 ]; then
      note "tando: DNS for $d does not point at $HOST yet. At your DNS provider, create:"
      cat "$TMPD/dns" >&2
      note "then run this again (--wait polls until it is right; --force skips the check)"
      [ -n "$FORCE" ] && { note "--force: going on anyway"; return 0; }
      return 1
    fi
    if [ $i = 0 ]; then   # every record to create, once; then a short line every minute
      note "DNS for $d does not point at $HOST yet. At your DNS provider, create:"
      cat "$TMPD/dns" >&2
    fi
    [ $((i % 6)) = 0 ] && note "waiting for DNS of $d..."
    sleep 10; i=$((i + 1))
  done
}

# www_kind domain -> www (starts with www.), apex (a registered name: the part after its first label
# is one label, like example.com, or a two-level public suffix, like example.co.uk) or sub (a
# sub-domain: app.example.com, shop.example.co.uk). WWW_SFX2 is a pragmatic list of the common
# two-level suffixes, not the full Public Suffix List: a name under a suffix missing from it is
# taken for a sub-domain (no www redirect); tando domain add --www redirect overrides that.
# The twin in server/tando-agent must stay identical (test/ui-test.sh runs both over one table).
WWW_SFX2=" \
  co.uk org.uk ac.uk gov.uk me.uk ltd.uk plc.uk sch.uk net.uk com.au net.au org.au \
  edu.au gov.au id.au co.nz net.nz org.nz govt.nz ac.nz co.jp or.jp ne.jp ac.jp go.jp \
  co.kr or.kr co.in net.in org.in firm.in gen.in ind.in ac.in com.br net.br org.br \
  gov.br com.mx org.mx gob.mx com.sg edu.sg com.my com.hk org.hk edu.hk com.tw org.tw \
  com.cn net.cn org.cn gov.cn co.id or.id ac.id web.id my.id sch.id go.id biz.id co.za \
  org.za net.za ac.za gov.za com.tr org.tr net.tr com.ar com.co com.ph com.vn co.th \
  ac.th or.th in.th com.pk com.ng com.eg com.sa com.ua com.pe com.ve co.il org.il co.ke \
"
www_kind() {
  case $1 in www.*) echo www; return;; esac
  local rest=${1#*.}
  case $rest in *.*) ;; *) echo apex; return;; esac
  case $WWW_SFX2 in *" $rest "*) echo apex; return;; esac
  echo sub
}
default_www() { case $(www_kind "$1") in sub) echo off;; *) echo redirect;; esac; }
# www_why domain: the one line `tando domain add` prints about the www handling it chose
www_why() {
  case $(www_kind "$1") in
    www) echo "$1 starts with www., so it redirects to ${1#www.}";;
    apex) echo "$1 is a registered name, so www.$1 redirects to it";;
    *) echo "$1 is a sub-domain, so it gets no www twin";;
  esac
}

# domain_live domain: wait (the server gives it up to 90 s) for the domain to answer through Caddy
# with a valid certificate; prints the outcome, fails when it does not
domain_live() {
  note "added $1; waiting up to 90 s for its certificate..."
  K_live="" K_error=""
  if agent_raw sudo domain-check "$APP" "$1" < /dev/null > "$TMPD/dc"; then kv_read "$TMPD/dc" live expires; fi
  if [ -n "$K_live" ]; then
    note "$K_live is live$(is_num "$K_expires" && printf ' (certificate until %s)' "$(TZ=UTC local_time "$K_expires" '+%Y-%m-%d')")"
    return 0
  fi
  kv_read "$TMPD/dc" error
  note "tando: $1 is added to $APP on $HOST, but it does not answer with a valid certificate yet${K_error:+: $K_error}"
  note "  likely: DNS does not point at $HOST yet, or ports 80/443 are closed in the cloud firewall;" \
    "Caddy keeps retrying by itself"
  note "  check: tando domain ls (CERTIFICATE column) ${UI_G_MID} again, waiting: tando domain add $1 --wait ${UI_G_MID} tando doctor"
  return 1
}

cmd_domain() {
  local op d="" w="" i=1 a pos=()
  # --www is read here (lib/args.sh checked it); --wait sets DNS_WAIT in bin/tando (parse)
  while [ $i -lt ${#ARGS[@]} ]; do
    a=${ARGS[$i]}
    case $a in
      --www) w=${ARGS[$((i + 1))]}; i=$((i + 2)); continue;;
      --wait) DNS_WAIT=1;;
      *) pos+=("$a");;
    esac
    i=$((i + 1))
  done
  op=${pos[0]:-ls} d=${pos[1]:-}
  resolve 1
  [ -z "${DEPLOY_KEY:-}" ] || die "tando domain needs the admin's login, not a deploy key"
  case $op in
    ls)
      agent sudo domain-ls "$APP" < /dev/null > "$TMPD/st"
      NOW=$(now)
      {
        printf 'DOMAIN\tWWW\tCERTIFICATE\n'
        awk -F '\t' -v OFS='\t' '$1 == "domain" { print $2, $3, $4 }' "$TMPD/st" |
          while IFS=$TAB read -r d w e; do
            if is_num "$e"; then e="until $(TZ=UTC local_time "$e" '+%Y-%m-%d')"; else e="none yet"; fi
            printf '%s\t%s\t%s\n' "$d" "$w" "$e"
          done
      } > "$TMPD/rows"
      ui_box_open "domains $APP" "$HOST"
      if [ "$(wc -l < "$TMPD/rows")" -le 1 ]; then ui_box_line "No domains yet: tando domain add example.com"
      else ui_table "l,l,l" < "$TMPD/rows"; fi
      ui_box_close "the app's own link stays too: tando status";;
    add)
      d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]'); d=${d%.}
      case $d in ""|*[!a-z0-9.-]*|.*|*..*) usage_err "not a domain name: $d" domain;; esac
      if [ -n "$w" ]; then
        case $w in redirect|serve|off) ;; *) usage_err "--www is redirect, serve or off" domain;; esac
        note "www: $w (--www $w)"
      else
        w=$(default_www "$d")
        note "www: $w ($(www_why "$d"); change it with --www redirect|serve|off)"
      fi
      server_addrs
      domain_dns "$d" "$w" || exit 1
      agent sudo domain-add "$APP" "$d" "$w" < /dev/null > "$TMPD/o"
      domain_live "$d";;
    rm)
      d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
      agent sudo domain-rm "$APP" "$d" < /dev/null > "$TMPD/o"
      note "removed $d from $APP (Caddy no longer answers for it)";;
  esac
}
