# lib/datanode.sh: app nodes whose PostgreSQL is on a data node (docs/DATA-NODE.md).
# The provisioning runs here, on the operator's machine (or the control plane): this client asks
# the data node for a project's role and database, and hands the app node only that role's
# password. The app node never holds a credential of the data node's superuser.

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
  local app=${1:-} dn=${2:-} kv aaddr="" daddr="" ca
  [ -n "$app" ] && [ -n "$dn" ] || usage_err "tando host link <app-node> <data-node>" host
  [ "$app" != "$dn" ] || usage_err "an app node and its data node are two servers" host
  shift 2
  for kv in "$@"; do
    case $kv in
      app_addr=*) aaddr=${kv#*=};; data_addr=*) daddr=${kv#*=};;
      *) usage_err "bad setting: $kv (app_addr=, data_addr=)" host;;
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
  dn_call "$dn" data-link "$app" "$aaddr" ${daddr:+"$daddr"} > "$TMPD/dl" || exit 1
  kv_read "$TMPD/dl" addr ca
  [ -n "$K_addr" ] && [ -n "$K_ca" ] || die "$dn gave no address or CA"
  ca=$(printf '%s' "$K_ca" | base64 -d 2> /dev/null) || die "$dn gave a CA that is not base64"
  printf '%s\n' "$ca" | agent sudo db-link "$dn" "$K_addr" "$app" > "$TMPD/o"
  note "linked: $app keeps its apps' databases on $dn ($K_addr:5432 and :6432, TLS verify-full);" \
    "$dn admits $aaddr. Next: database = postgres in an app's tando.conf on $app, then tando up"
}

# db_remote_provision (deploy, after configure): the app's role and database on the data node
# (K_db_remote) with its limits; a new password only when the app node has none (K_db_url=0),
# piped to the app node's env on stdin, never on a command line or in a file here
db_remote_provision() {
  local dn=$K_db_remote node=$K_db_node new="" pw
  valid_host "$dn" && [ -f "$CFG/hosts/$dn" ] ||
    die "$HOST keeps its databases on the data node $dn, which is not a host here: tando host add $dn <user@address>"
  valid_host "$node" || die "$HOST does not know its name on $dn: tando host link $HOST $dn"
  [ "$K_db_url" = 1 ] || new=new=1
  pw=$(dn_call "$dn" data-db ensure "$APP" "$node" "pool=$K_db_pool" "st=$K_db_st" "it=$K_db_it" "tf=$K_db_tf" $new) || exit 1
  pw=$(printf '%s\n' "$pw" | sed -n 's/^password=//p')
  if [ -n "$new" ]; then
    [ -n "$pw" ] || die "$dn gave no password for the database of $APP"
    printf 'password=%s\n' "$pw" | agent sudo db-remote-set "$APP" > /dev/null
  fi
  return 0
}

# db_remote_drop (destroy): the database on the data node goes with the app
db_remote_drop() {
  local dn=$1 node=$2
  if valid_host "$dn" && [ -f "$CFG/hosts/$dn" ] && valid_host "$node" &&
     dn_call "$dn" data-db drop "$APP" "$node" > /dev/null; then
    note "dropped the database of $APP on $dn"
  else
    note "the database of $APP on the data node $dn is still there: drop it with" \
      "ssh to $dn, then sudo /opt/tando/bin/tando-agent data-db drop $APP ${node:-<app-node>}"
  fi
}
