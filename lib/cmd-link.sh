# shellcheck shell=bash
# help: link [app]   print the app's address (its own domain, else its link), for scripts
#
# lib/cmd-link.sh: `tando link`; also used by `tando open`. One ssh call (nx_probe). bash 3.2.

. "$TANDO_HOME/lib/cmd-next.sh"

# link_get: the URL into LINK, or exits with the reason
link_get() {
  resolve 1
  nx_probe "$APP" || { ssh_explain "$TMPD/nx.err" || note "tando: cannot reach $HOST"; exit 1; }
  nx_app "$APP" || die "$APP is not on $HOST yet: tando up"
  [ -n "$N_rel" ] || die "$APP is not deployed yet: tando up"
  LINK=$(nx_url "$APP")
}

cmd_link() { link_get; printf '%s\n' "$LINK"; }
