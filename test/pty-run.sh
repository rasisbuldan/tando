#!/bin/bash
# test/pty-run.sh <output file> <command> [args...]: run the command on a pseudo-terminal and keep
# what it wrote in the file. script(1) takes the command differently on macOS/BSD (script file
# cmd args) and with util-linux (script -c "cmd" file).
set -u
out=${1:?usage: pty-run.sh <output file> <command> [args...]}; shift
if script --version 2> /dev/null | grep -q util-linux; then
  cmd=$(printf '%q ' "$@")
  exec script -q -e -c "$cmd" "$out"
else
  exec script -q "$out" "$@"
fi
