#!/bin/bash
# uninstall.sh: remove a tando client installed by install.sh.
#
#   ./uninstall.sh                 from ~/.local
#   ./uninstall.sh --prefix DIR    from DIR
#   ./uninstall.sh --system        from /usr/local (sudo when it is not writable)
#   --purge                        also remove the host registry ~/.config/tando (asks first)
#
# Removes PREFIX/lib/tando and the paths listed in its .manifest (the launcher and completion
# files), and nothing else. Servers are not touched: their agents and apps keep running.
set -u
prefix=$HOME/.local system=0 purge=0 SUDO=""
die() { echo "uninstall: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case $1 in
    --prefix) prefix=${2:-}; shift;;
    --system) system=1; prefix=/usr/local;;
    --purge) purge=1;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) die "unknown argument: $1";;
  esac
  shift
done
case $prefix in /?*) ;; *) die "--prefix needs an absolute directory";; esac
prefix=${prefix%/}
dest=$prefix/lib/tando
[ -f "$dest/.manifest" ] || die "no tando installed by install.sh in $prefix ($dest/.manifest missing)"
if [ ! -w "$prefix/lib" ]; then
  [ "$system" = 1 ] || die "$prefix is not writable (use --system for sudo)"
  SUDO=sudo
fi

# only paths under the prefix, exactly as install.sh wrote them
while IFS= read -r p; do
  case $p in "#"*|"") continue;; esac
  case $p in "$prefix"/*) ;; *) echo "uninstall: skipping $p (outside $prefix)" >&2; continue;; esac
  case $p in *..*) continue;; esac
  if [ -L "$p" ] || [ -f "$p" ]; then $SUDO rm -f "$p" && echo "removed $p"; fi
done < "$dest/.manifest"
$SUDO rm -rf "${dest:?}" && echo "removed $dest"

if [ "$purge" = 1 ]; then
  cfg=${TANDO_CONFIG_DIR:-$HOME/.config/tando}
  if [ -d "$cfg" ]; then
    printf 'Remove the host registry %s? Type yes: ' "$cfg"
    IFS= read -r a || a=""
    if [ "$a" = yes ]; then rm -rf "${cfg:?}" && echo "removed $cfg"; else echo "kept $cfg"; fi
  fi
fi
