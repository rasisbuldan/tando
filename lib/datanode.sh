# lib/datanode.sh: app nodes whose PostgreSQL is on a data node (docs/DATA-NODE.md).
# The provisioning runs here, on the operator's machine (or the control plane): this client asks
# the data node for a project's role and database, and hands the app node only that role's
# password. The app node never holds a credential of the data node's superuser.

# The link record (written by host link, here only): $CFG/links/<app-node> holds data= (the data
# node's host name here), node= (the app node's name on it) and ca= (the CA's SHA-256). Provisioning
# and drops act on it alone: an app node's own report of where its databases are is only compared
# with it, never followed (a compromised app node must not aim them at another project).
link_get() { # app-node key
  [ -f "$CFG/links/$1" ] || return 1
  sed -n "s/^$2=//p" "$CFG/links/$1" | head -1
}
# link_check: the app node's report (K_db_remote, K_db_node) against the record; sets LINK_DN LINK_NODE
link_check() {
  LINK_DN=$(link_get "$HOST" data) && LINK_NODE=$(link_get "$HOST" node) ||
    die "$HOST says its databases are on the data node ${1:-?}, but no link was made from here: refusing (tando host link $HOST <data-node> records it)"
  valid_host "$LINK_DN" && valid_host "$LINK_NODE" || die "the link record $CFG/links/$HOST is damaged: tando host link $HOST <data-node> again"
  if [ "${1:-}" != "$LINK_DN" ] || [ "${2:-}" != "$LINK_NODE" ]; then
    die "REFUSED: $HOST reports its databases on data node '${1:-}' as '${2:-}', but it was linked to '$LINK_DN' as '$LINK_NODE'." \
      "Nothing was changed on any data node. A server that reports another link may be compromised: check it before anything else."
  fi
}

# dn_call <data-node> verb args...: the data node's agent (its own host entry and connection),
# in a subshell so this command's host stays the app node
dn_call() {
  local dn=$1; shift
  ( host_use "$dn"; agent sudo "$@" < /dev/null )
}

# tando host link <app-node> <data-node> [app_addr=A] [data_addr=B]: the data node admits the app
# node's address (pg_hba, firewall) and the app node pins the data node's CA; from then on an app
# with database = postgres on the app node gets its database on the data node
host_link() {
  local app=${1:-} dn=${2:-} kv aaddr="" daddr="" ca move="" old
  [ -n "$app" ] && [ -n "$dn" ] || usage_err "tando host link <app-node> <data-node>" host
  [ "$app" != "$dn" ] || usage_err "an app node and its data node are two servers" host
  shift 2
  for kv in "$@"; do
    case $kv in
      app_addr=*) aaddr=${kv#*=};; data_addr=*) daddr=${kv#*=};;
      --move) move=move=1;;   # the app node's name now points at another address: its projects follow
      *) usage_err "bad setting: $kv (app_addr=, data_addr=, --move)" host;;
    esac
  done
  for kv in "$aaddr" "$daddr"; do
    case $kv in *[!0-9a-fA-F.:]*) usage_err "bad address: $kv (an IP address)" host;; esac
  done
  ( host_use "$dn"; agent info ) > "$TMPD/dn" || exit 1
  kv_read "$TMPD/dn" role
  [ "$K_role" = data ] || die "$dn is not a data node: tando host setup $dn role=data"
  host_use "$app"
  agent info > "$TMPD/an"
  kv_read "$TMPD/an" role ip db_host
  [ "$K_role" != data ] || die "$app is a data node itself"
  [ -n "$K_db_host" ] && [ "$K_db_host" != "$dn" ] && die "$app keeps its databases on $K_db_host already"
  [ -n "$aaddr" ] || aaddr=$K_ip
  [ -n "$aaddr" ] || die "$app has no default route: give its address, app_addr=<ip>"
  old=$(link_get "$app" data) && [ "$old" != "$dn" ] && die "$app is linked to $old already (from here)"
  dn_call "$dn" data-link "$app" "$aaddr" ${daddr:+"$daddr"} $move > "$TMPD/dl" || exit 1
  kv_read "$TMPD/dl" addr ca
  [ -n "$K_addr" ] && [ -n "$K_ca" ] || die "$dn gave no address or CA"
  ca=$(printf '%s' "$K_ca" | base64 -d 2> /dev/null) || die "$dn gave a CA that is not base64"
  printf '%s\n' "$ca" | agent sudo db-link "$dn" "$K_addr" "$app" > "$TMPD/o"
  mkdir -p "$CFG/links" && chmod 700 "$CFG/links" &&
    printf 'data=%s\nnode=%s\nca=%s\n' "$dn" "$app" "$(printf '%s\n' "$ca" | openssl x509 -noout -fingerprint -sha256 2> /dev/null | sed 's/.*=//')" |
    write_file "$CFG/links/$app" || die "cannot write $CFG/links/$app"
  note "linked: $app keeps its apps' databases on $dn ($K_addr:5432 and :6432, TLS verify-full);" \
    "$dn admits $aaddr. Next: database = postgres in an app's tando.conf on $app, then tando up"
}

# db_remote_provision (deploy, after configure): the app's role and database on the data node
# (K_db_remote) with its limits; a new password only when the app node has none (K_db_url=0),
# piped to the app node's env on stdin, never on a command line or in a file here
db_remote_provision() {
  local dn node new="" pw k v pool=5 st=30s it=5m tf=1G
  link_check "$K_db_remote" "$K_db_node"
  dn=$LINK_DN node=$LINK_NODE
  [ -f "$CFG/hosts/$dn" ] || die "$HOST is linked to the data node $dn, which is not a host here: tando host add $dn <user@address>"
  # the limits from this tando.conf (the server checks them against its own bounds), never the
  # app node's report
  while IFS='=' read -r k v; do
    case $k in db_pool) pool=$v;; db_statement_timeout) st=$v;; db_idle_tx_timeout) it=$v;; db_temp_limit) tf=$v;; esac
  done <<EOF
${C_logs:-}
EOF
  [ "$K_db_url" = 1 ] || new=new=1
  pw=$(dn_call "$dn" data-db ensure "$APP" "$node" "pool=$pool" "st=$st" "it=$it" "tf=$tf" $new) || exit 1
  pw=$(printf '%s\n' "$pw" | sed -n 's/^password=//p')
  if [ -n "$new" ]; then
    [ -n "$pw" ] || die "$dn gave no password for the database of $APP"
    printf 'password=%s\n' "$pw" | agent sudo db-remote-set "$APP" > /dev/null
  fi
  return 0
}

# db_remote_drop (destroy): the database on the data node goes with the app
db_remote_drop() {
  local dn node
  dn=$(link_get "$HOST" data) && node=$(link_get "$HOST" node) || return 0
  if [ -f "$CFG/hosts/$dn" ] && dn_call "$dn" data-db drop "$APP" "$node" > /dev/null; then
    note "dropped the database of $APP on $dn"
  else
    note "the database of $APP on the data node $dn is still there: drop it with" \
      "ssh to $dn, then sudo /opt/tando/bin/tando-agent data-db drop $APP $node"
  fi
}
