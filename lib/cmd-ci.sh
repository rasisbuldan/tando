# lib/cmd-ci.sh: restricted deploy keys for CI. Sourced by bin/tando for `tando ci ...`, and by
# resolve() when TANDO_DEPLOY_KEY is set (CI) or a host entry has kind=deploy.
# help: ci setup [--previews]|ls|revoke <id|fingerprint|all>|rotate|github|hook   deploy keys for CI (admin)
#
# The server side is tando-gate, a Go program (srv/gate; installed as /opt/tando/bin/tando-gate by
# install_helpers, the binary for the server's CPU). See docs/CI.md.
# bash 3.2. Nothing the server prints is evaluated: output is stripped and read by whitelist.

GATE_BIN=/opt/tando/bin/tando-gate

ci_usage() {
  cat >&2 <<'EOF'
usage: tando ci <command>              (run by the admin, in the app's directory)
  setup                  create a deploy key for this app; prints it once with the CI secrets
  setup --previews       a key for previews only (<app>-<branch>): it cannot deploy the app itself
  rotate                 a new key replaces every existing one (they stop working now)
  ls                     keys with fingerprint, created and last deploy
  revoke <id|SHA256:..|all>
  github [--ref TAG|SHA] [--repo URL] [--branch B] [--node N] [--env NAME] [--force]
                         write .github/workflows/deploy.yml
  hook [--branch B] [--force] | hook --remove
                         git pre-push hook: deploy the pushed commit before the push
EOF
}

# ---- deploy-key mode (CI): TANDO_DEPLOY_KEY, TANDO_HOST, TANDO_PORT, TANDO_KNOWN_HOSTS ----

# plain line-per-step output when there is no terminal (CI logs), unless TANDO_PLAIN=0
ci_key_ui() {
  case ${TANDO_PLAIN:-} in
    0) return 0;;
    1) ;;
    *) [ "${UI_ISTTY:-0}" = 0 ] || return 0;;
  esac
  # (2> /dev/null: a reader that stops early, as in `| head`, is not an error to print)
  ui_box_open() { UI_BOX=1; printf '%s%s\n' "$1" "${2:+ ($2)}" 2> /dev/null; }
  ui_box_line() { printf '%s\n' "$1" 2> /dev/null | sed 's/^ *//' 2> /dev/null; }
  ui_box_sep() { [ -z "${1:-}" ] || printf -- '-- %s\n' "$1" 2> /dev/null; }
  ui_box_close() { UI_BOX=0; [ -z "${1:-}" ] || printf '%s\n' "$1" 2> /dev/null; }
  ui_kv() { printf '%s: %s\n' "$1" "$2" 2> /dev/null; }
  ui_step() { printf '[%s/%s] %-9s %-4s %s\n' "$1" "$2" "$3" "$4" "${5:-}" 2> /dev/null | sed 's/ *$//' 2> /dev/null; }
}

ci_key_resolve() {
  local key=$TANDO_DEPLOY_KEY host=${TANDO_HOST:-} port=${TANDO_PORT:-22} cp="$CFG/cm/%C" a b c t k
  [ -n "$APP" ] || APP=${TANDO_APP:-}
  [ -n "$APP" ] || die "no app: run in a directory with tando.conf, or set TANDO_APP"
  valid_app "$APP" || die "bad app name: $APP (a-z, 0-9, -; 2-24 characters)"
  [ -n "$host" ] || die "TANDO_DEPLOY_KEY is set but TANDO_HOST is not"
  case $host in *[!A-Za-z0-9.-]*|-*) die "bad TANDO_HOST: $host";; esac
  is_num "$port" || die "bad TANDO_PORT: $port"
  [ -n "${TANDO_KNOWN_HOSTS:-}" ] ||
    die "TANDO_KNOWN_HOSTS is not set: the server's host key is always checked (tando ci setup prints it)"
  case $key in
    *"PRIVATE KEY-----"*) printf '%s\n' "$key" | tr -d '\r' > "$TMPD/deploy_key";;
    *) [ -f "$key" ] || die "TANDO_DEPLOY_KEY: neither a private key nor a key file"
       tr -d '\r' < "$key" > "$TMPD/deploy_key";;
  esac
  chmod 600 "$TMPD/deploy_key"
  # known_hosts lines ("[host]:port type key" or "type key"): the keys are bound to a fixed alias,
  # so the check does not depend on how the runner spells the host name
  printf '%s\n' "$TANDO_KNOWN_HOSTS" | tr -d '\r' | while read -r a b c; do
    case $a in ssh-*|ecdsa-*) t=$a k=$b;; *) t=$b k=$c;; esac
    case $t in ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ssh-rsa) ;; *) continue;; esac
    case $k in ""|*[!A-Za-z0-9+/=]*) continue;; esac
    printf 'tando-deploy-host %s %s\n' "$t" "$k"
  done > "$TMPD/known_hosts"
  [ -s "$TMPD/known_hosts" ] || die "TANDO_KNOWN_HOSTS holds no usable host key"
  HOST=$host TARGET="tando-d-$APP@$host"
  mkdir -p "$CFG/cm" && chmod 700 "$CFG/cm"
  if [ $((${#CFG} + 61)) -gt 103 ]; then   # a private, checked directory (lib/common.sh)
    ctl_dir
    cp="$CTL_DIR/%C"
  fi
  SSHO=(-F /dev/null -p "$port" -i "$TMPD/deploy_key" -o IdentitiesOnly=yes -o IdentityAgent=none
        -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$TMPD/known_hosts"
        -o GlobalKnownHostsFile=/dev/null -o HostKeyAlias=tando-deploy-host
        -o ControlMaster=auto -o "ControlPath=$cp" -o ControlPersist=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3
        -o ConnectTimeout=10 -o ClearAllForwardings=yes -o ForwardAgent=no -o RequestTTY=no
        -o LogLevel=ERROR)
  ci_key_ui
}

# ---- admin side ----------------------------------------------------------------------------

ci_admin() {
  [ -z "${TANDO_DEPLOY_KEY:-}" ] || die "tando ci $1 is for the admin: unset TANDO_DEPLOY_KEY"
  resolve 1
  [ "$(host_get "$HOST" kind)" != deploy ] || die "tando ci $1 needs the admin's host entry, not a deploy key"
}

# gate_admin verb args...: root on the server through the admin's sudo; stdin is passed on
gate_admin() {
  local a rc
  for a in "$@"; do case $a in ""|*[!a-z0-9-]*) die "internal: unsafe argument '$a'";; esac; done
  ssh "${SSHO[@]}" "$TARGET" "sudo -n $GATE_BIN admin $*" 2> "$TMPD/err" | strip
  rc=${PIPESTATUS[0]}
  [ -s "$TMPD/err" ] && strip < "$TMPD/err" >&2
  return "$rc"
}

# install or update the gate and its host-wide sshd settings (also run by `tando host setup`)
ci_install_gate() {
  # (host setup has just installed it with the other helpers: HELPERS_INSTALLED says so)
  if { [ -n "${HELPERS_INSTALLED:-}" ] || install_helpers tando-gate; } &&
     ssh "${SSHO[@]}" "$TARGET" 'sudo -n /opt/tando/bin/tando-gate admin install > /dev/null' 2> "$TMPD/err"; then :; else
    die "could not install the CI gate: $(strip < "$TMPD/err" | tail -2 | tr '\n' ' ')"
  fi
}

ci_date() { # epoch -> "2026-11-14 17:01" in GMT
  ui_int "$1" || { printf -- -; return; }
  TZ=UTC local_time "$1" '+%Y-%m-%d %H:%M'
}

ci_setup() { # [rotate|previews]
  local mode=${1:-} h port kh line n=0 envname=tando-deploy
  case $mode in rotate) ci_admin rotate;; *) ci_admin setup;; esac
  command -v ssh-keygen > /dev/null || die "ssh-keygen not found"
  ci_install_gate
  ssh-keygen -q -t ed25519 -N '' -C "tando-ci-$APP" -f "$TMPD/ci_key" < /dev/null > /dev/null ||
    die "ssh-keygen failed"
  gate_admin key-add "$APP" $mode < "$TMPD/ci_key.pub" > "$TMPD/o" || bail 1
  kv_read "$TMPD/o" keyid fingerprint user revoked
  case $K_keyid in ""|*[!0-9a-f]*) die "the server returned no key id";; esac
  h=${TARGET#*@} port=$(host_get "$HOST" port)
  if [ "${port:-22}" = 22 ]; then kh=$h; else kh="[$h]:$port"; fi
  ui_box_open "ci ${mode:-setup} $APP" "$HOST"
  ui_kv "login" "$K_user@$h port ${port:-22}"
  if [ "$mode" = previews ]; then
    envname=tando-preview
    ui_kv "can" "make, deploy to and remove previews $APP-<branch>; read $APP's status; never deploy $APP"
  else
    ui_kv "can" "upload, activate, status of $APP, and its previews; nothing else"
  fi
  ui_kv "note" "the code it ships runs with $APP's env and data: whoever holds the key can read them"
  ui_kv "key" "$K_keyid  $K_fingerprint"
  [ "$mode" = rotate ] && ui_kv "revoked" "$K_revoked older key(s); their sessions were ended"
  ui_box_close "store these as CI secrets now: the key is not kept"
  {
    printf -- '--- TANDO_HOST\n%s\n' "$h"
    printf -- '--- TANDO_PORT\n%s\n' "${port:-22}"
    printf -- '--- TANDO_KNOWN_HOSTS\n'
    sed -nE 's/^hostkey=((ssh|ecdsa)-[a-z0-9-]+ [A-Za-z0-9+\/=]+)$/\1/p' "$TMPD/o" |
      while IFS= read -r line; do printf '%s %s\n' "$kh" "$line"; done
    printf -- '--- TANDO_DEPLOY_KEY\n'
    cat "$TMPD/ci_key"
    printf -- '--- end\n'
  }
  rm -f "$TMPD/ci_key"
  if [ "$mode" = previews ]; then
    note "GitHub: gh secret set <NAME> --env $envname (paste each value); allow pull request branches on that environment, never on tando-deploy (docs/CI.md, \"Preview apps from CI\")"
  else
    note "GitHub: gh secret set <NAME> --env $envname (paste each value), then: tando ci github"
  fi
}

ci_ls() {
  local id fp created used who scope
  ci_admin ls
  gate_admin key-ls "$APP" > "$TMPD/keys" || bail 1
  ui_box_open "deploy keys $APP" "$HOST"
  if ! grep -q '^key	' "$TMPD/keys"; then
    ui_box_line "no deploy keys (tando ci setup)"; ui_box_close; return 0
  fi
  {
    printf 'ID\tFINGERPRINT\tCREATED (GMT)\tLAST DEPLOY (GMT)\tBY\tMAY\n'
    while IFS='	' read -r _ id fp created used who scope; do
      [ "$used" = - ] && used=never || used=$(ci_date "$used")
      [ "$scope" = previews ] && scope=previews || scope=deploy
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$fp" "$(ci_date "$created")" "$used" "$who" "$scope"
    done < <(grep '^key	' "$TMPD/keys")
  } > "$TMPD/rows"
  ui_table "l,l:20-52,l!2,l!1,l!3,l" < "$TMPD/rows"
  ui_box_close
}

ci_revoke() { # id | SHA256:fingerprint | all
  local sel=${1:-}
  case $sel in
    all) ;;
    SHA256:*) case ${sel#SHA256:} in *[!A-Za-z0-9+/]*|"") die "bad fingerprint: $sel";; esac;;
    *) case $sel in ""|*[!0-9a-f]*) die "usage: tando ci revoke <key id|SHA256:fingerprint|all>";; esac;;
  esac
  ci_admin revoke
  printf '%s\n' "$sel" | gate_admin key-revoke "$APP" > "$TMPD/o" || bail 1
  kv_read "$TMPD/o" revoked
  note "revoked $K_revoked key(s) of $APP; open sessions of its deploy user were ended"
}

# ci_template <name>: a file of templates/ in this tando (a source checkout or an install)
ci_template() {
  CI_TPL=$TANDO_HOME/templates/$1
  [ -f "$CI_TPL" ] || die "this tando has no $1 template ($CI_TPL is missing): reinstall tando with a current install.sh, which ships templates/"
}

# where tando comes from, for the workflow to install the same one: a git checkout's origin and
# commit, or an installed release (VERSION, and install.sh's REPO or $TANDO_REPO) -> CI_REPO CI_REF
ci_tando_source() {
  local r
  CI_REPO="" CI_REF=""
  if git -C "$TANDO_HOME" rev-parse --is-inside-work-tree > /dev/null 2>&1 &&
     [ "$(git -C "$TANDO_HOME" rev-parse --show-toplevel 2> /dev/null)" = "$(cd "$TANDO_HOME" && pwd -P)" ]; then
    CI_REPO=$(git -C "$TANDO_HOME" remote get-url origin 2> /dev/null) || CI_REPO=""
    CI_REF=$(git -C "$TANDO_HOME" describe --tags --exact-match HEAD 2> /dev/null) ||
      CI_REF=$(git -C "$TANDO_HOME" rev-parse --verify -q HEAD 2> /dev/null) || CI_REF=""
  fi
  if [ -z "$CI_REPO" ]; then
    r=${TANDO_REPO:-}
    [ -n "$r" ] || r=$(sed -n 's/^REPO=\${TANDO_REPO:-\([^}]*\)}.*/\1/p' "$TANDO_HOME/install.sh" 2> /dev/null | head -1)
    case $r in ""|OWNER/*) ;; https://*|git@*|ssh://*|file://*|/*) CI_REPO=$r;; */*) CI_REPO=https://github.com/$r;; esac
  fi
  if [ -z "$CI_REF" ] && [ -f "$TANDO_HOME/VERSION" ]; then
    CI_REF=v$(tr -cd '0-9A-Za-z.-' < "$TANDO_HOME/VERSION")
    [ "$CI_REF" != v ] || CI_REF=""
  fi
}

# ---- tando ci github: .github/workflows/deploy.yml ------------------------------------------

ci_github() {
  local ref="" repo="" branch="" node="" envname=tando-deploy force="" sha="" fetch out tpl
  local top sub wdir lock=0 pkg=0
  while [ $# -gt 0 ]; do
    case $1 in
      --ref) ref=${2:-}; shift 2;;
      --repo) repo=${2:-}; shift 2;;
      --branch) branch=${2:-}; shift 2;;
      --node) node=${2:-}; shift 2;;
      --env) envname=${2:-}; shift 2;;
      --force) force=1; shift;;
      *) die "ci github: unknown option $1";;
    esac
  done
  conf_load || die "no tando.conf here"
  valid_app "$C_app" || die "bad app in tando.conf"
  top=$(git rev-parse --show-toplevel 2> /dev/null) || die "run tando ci github inside your app's git repository"
  sub=$(git rev-parse --show-prefix); sub=${sub%/}
  [ -n "$branch" ] || branch=$(git symbolic-ref --short HEAD 2> /dev/null) || branch=main
  case $branch in ""|-*|*..*|*[!A-Za-z0-9._/-]*) die "bad branch: $branch";; esac
  # tando itself, pinned: a tag or a commit of where this tando came from, never a branch
  ci_tando_source
  [ -n "$repo" ] || repo=$CI_REPO
  [ -n "$repo" ] || die "cannot tell where the workflow should download tando from (this tando is not a git checkout with an origin, and its install names no release repository): use --repo https://github.com/<owner>/tando, or set TANDO_REPO=<owner>/tando"
  case $repo in https://*|git@*|ssh://*|file://*|/*) ;; *) die "bad --repo: $repo";; esac
  case $repo in *[!A-Za-z0-9@:/._~+-]*) die "bad --repo: $repo";; esac
  [ -n "$ref" ] || ref=$CI_REF
  [ -n "$ref" ] || die "cannot tell which version of tando the workflow should install: use --ref <tag or commit>"
  case $ref in -*|*[!A-Za-z0-9._-]*) die "bad --ref: $ref";; esac
  if printf '%s' "$ref" | grepq -E '^[0-9a-f]{40}$'; then
    sha=$ref fetch=$ref
  else
    case $ref in main|master|trunk|develop|dev|HEAD|latest|stable) die "--ref $ref looks like a moving branch: give a tag or a commit";; esac
    git -C "$TANDO_HOME" show-ref -q --verify "refs/heads/$ref" 2> /dev/null &&
      die "--ref $ref is a branch of tando: give a tag or a commit"
    sha=$(git -C "$TANDO_HOME" rev-parse -q --verify "refs/tags/$ref^{commit}" 2> /dev/null) || sha=""
    [ -n "$sha" ] || note "warning: this tando cannot resolve tag $ref to a commit (not a git checkout that has it), so the workflow does not pin it; a moved tag would go unnoticed"
    fetch=refs/tags/$ref
  fi
  # node: setup-node (with the npm cache when there is a lockfile) only when there is a package.json
  [ -f package.json ] && pkg=1
  [ -f package-lock.json ] && lock=1
  if [ -z "$node" ]; then
    node=24; [ -f .nvmrc ] && node=$(tr -cd '0-9.' < .nvmrc)
    [ -n "$node" ] || node=24
  fi
  case $node in *[!0-9.x]*|"") die "bad --node: $node";; esac
  case $envname in ""|*[!A-Za-z0-9_-]*) die "bad --env: $envname";; esac
  wdir=${sub:-.}
  out=$top/.github/workflows/deploy.yml
  [ -f "$out" ] && [ -z "$force" ] && die "$out exists (use --force to replace it)"
  ci_template github-deploy.yml; tpl=$CI_TPL
  mkdir -p "$top/.github/workflows"
  awk -v app="$C_app" -v branch="$branch" -v repo="$repo" -v ref="$ref" -v fetch="$fetch" \
      -v sha="$sha" -v node="$node" -v pkg="$pkg" -v lock="$lock" -v wdir="$wdir" -v envn="$envname" '
    /^ *# @if node$/ { skip = !pkg; next }
    /^ *# @if lock$/ { skip = !lock; next }
    /^ *# @if nolock$/ { skip = !(pkg && !lock); next }
    /^ *# @end$/ { skip = 0; next }
    skip { next }
    { gsub(/@APP@/, app); gsub(/@BRANCH@/, branch); gsub(/@REPO@/, repo); gsub(/@REF@/, ref)
      gsub(/@FETCH@/, fetch); gsub(/@SHA@/, sha); gsub(/@NODE@/, node); gsub(/@WDIR@/, wdir)
      gsub(/@ENV@/, envn); print }' "$tpl" > "$out.tmp" && mv "$out.tmp" "$out"
  note "wrote ${out#$top/}: deploys $C_app on every push to $branch, with tando $ref${sha:+ ($sha)}"
  note "secrets (environment $envname): TANDO_DEPLOY_KEY TANDO_HOST TANDO_PORT TANDO_KNOWN_HOSTS (tando ci setup)"
  note "restrict the environment $envname to the branch $branch (Settings > Environments) so other branches cannot read the key"
}

# ---- tando ci hook: git pre-push --------------------------------------------------------------

ci_hook() {
  local branch="" force="" remove="" hooks f sub top
  while [ $# -gt 0 ]; do
    case $1 in
      --branch) branch=${2:-}; shift 2;;
      --force) force=1; shift;;
      --remove) remove=1; shift;;
      *) die "ci hook: unknown option $1";;
    esac
  done
  top=$(git rev-parse --show-toplevel 2> /dev/null) || die "not inside a git repository"
  hooks=$(git rev-parse --git-path hooks)
  case $hooks in /*) ;; *) hooks=$PWD/$hooks;; esac
  f=$hooks/pre-push
  if [ -n "$remove" ]; then
    [ -f "$f" ] && grep -q '^# tando pre-push hook' "$f" || die "no tando pre-push hook here"
    rm -f "$f"; note "removed $f"; return 0
  fi
  conf_load || die "no tando.conf here (run tando ci hook in the app's directory)"
  [ -n "$branch" ] || branch=$(git symbolic-ref --short HEAD 2> /dev/null) || branch=main
  case $branch in ""|-*|*..*|*[!A-Za-z0-9._/-]*) die "bad branch: $branch";; esac
  if [ -f "$f" ] && ! grep -q '^# tando pre-push hook' "$f" && [ -z "$force" ]; then
    die "$f exists and is not tando' (use --force to replace it)"
  fi
  ci_template pre-push
  sub=$(git rev-parse --show-prefix); sub=${sub%/}
  case "$TANDO_HOME$sub" in *"'"*) die "paths with a single quote are not supported";; esac
  mkdir -p "$hooks"
  awk -v tando="$TANDO_HOME/bin/tando" -v branch="$branch" -v appdir="${sub:-.}" '
    { gsub(/@TANDO@/, tando); gsub(/@BRANCH@/, branch); gsub(/@APPDIR@/, appdir); print }' \
    "$CI_TPL" > "$f.tmp" && chmod 755 "$f.tmp" && mv "$f.tmp" "$f" ||
    { rm -f "$f.tmp"; die "could not write $f"; }
  note "installed $f: a push of $branch first deploys the pushed commit of $C_app (built from a clean"
  note "checkout of that commit, not your working tree). The deploy happens before the push reaches the remote."
  note "a failed deploy does not stop the push unless: git config tando.hookstrict true"
  note "uncommitted changes are warned about (not deployed); to refuse instead: git config tando.hookdirty refuse"
}

cmd_ci() {
  case ${ARGS[1]:-} in
    setup) case ${ARGS[2]:-} in
        "") ci_setup;;
        --previews) ci_setup previews;;
        *) ci_usage; exit 1;;
      esac;;
    rotate) ci_setup rotate;;
    ls) ci_ls;;
    revoke) ci_revoke "${ARGS[2]:-}";;
    github) ci_github "${ARGS[@]:2}";;
    hook) ci_hook "${ARGS[@]:2}";;
    *) ci_usage; exit 1;;
  esac
}
