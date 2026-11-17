# shellcheck shell=bash
# help: ssh [app] [-- command]   a shell on the server; with an app, as the app's user in its sandbox
#
# lib/cmd-ssh.sh: `tando ssh`. Uses the host entry's ssh options (key, port, host key).
#   tando ssh                  the admin's own login shell on the server
#   tando ssh <app>            an interactive shell as the app's user, inside the app's sandbox
#                              (its env loaded, cwd its current release, only shared/ writable)
#   tando ssh <app> -- cmd...  one command there, its words joined with spaces as ssh does; its exit
#                              status is tando's. A terminal when this one has one, else stdin and
#                              stdout are passed through.
#   tando ssh -a <app> [-- cmd...]   the same (with -a, every remaining word is the command)
# The command travels hex-encoded on stdin to the agent's `shell-put` (a token comes back for `shell`), so no shell between
# here and the sandbox parses it. Admin only: a deploy key is refused here and by tando-gate.
# bash 3.2.

cmd_ssh() {
  local named="" cmd="" hex
  if [ -n "${APP:-}" ]; then   # -a <app>
    named=1
    [ ${#ARGS[@]} -gt 1 ] && cmd="${ARGS[*]:1}"
  elif [ -n "${ARGS[1]:-}" ]; then
    named=1 APP=${ARGS[1]}
    [ ${#ARGS[@]} -gt 2 ] && cmd="${ARGS[*]:2}"
  fi
  resolve 0
  [ -z "${DEPLOY_KEY:-}" ] || die "tando ssh needs the admin's login, not a deploy key"
  if [ -z "$named" ]; then exec ssh -t "${SSHO[@]}" "$TARGET"; fi
  valid_app "$APP" || die "bad app name: $APP"
  local caps
  # shellcheck disable=SC2029 # AGENT_BIN is a constant path
  # lint: allow RL04 AGENT_BIN is a constant path
  caps=$(ssh "${SSHO[@]}" "$TARGET" "grep -o '^  shell[a-z-]*)' $AGENT_BIN" < /dev/null 2> /dev/null)
  case $caps in *"shell)"*) ;; *) die "the agent on $HOST has no shell verb (an older tando): tando host setup $HOST updates it";; esac
  if [ -z "$cmd" ]; then
    { [ -t 0 ] && [ -t 1 ]; } ||
      die "an interactive shell needs a terminal; tando ssh $APP -- <command> runs one command"
    # shellcheck disable=SC2029 # expanded here on purpose
    # lint: allow RL04 APP passed valid_app, AGENT_BIN is a constant path
    exec ssh -t "${SSHO[@]}" "$TARGET" "sudo -n $AGENT_BIN shell $APP"
  fi
  case $cmd in *"
"*) die "the command has a newline: put it in a script and run that";; esac
  [ ${#cmd} -le 4096 ] || die "the command is longer than 4096 characters: put it in a script"
  hex=$(printf '%s' "$cmd" | od -An -v -tx1 | tr -d ' \n')
  # the command goes on stdin to shell-put, which keeps it root-only and gives a token: on the
  # server no command line (sudo's, systemd-run's, bash's) carries it. Older agents: as an argument
  case $caps in
    *"shell-put)"*)
      local tok
      # shellcheck disable=SC2029 # expanded here on purpose
      # lint: allow RL04 APP passed valid_app, AGENT_BIN is a constant path
      tok=$(printf '%s\n' "$hex" | ssh "${SSHO[@]}" "$TARGET" "sudo -n $AGENT_BIN shell-put $APP" | sed -n 's/^token=//p')
      case $tok in ""|*[!0-9a-f]*) die "could not hand the command to the server (tando doctor)";; esac
      hex=@$tok;;
  esac
  if [ -t 0 ] && [ -t 1 ]; then
    # shellcheck disable=SC2029 # expanded here on purpose
    # lint: allow RL04 APP passed valid_app, hex is [0-9a-f]+, AGENT_BIN is a constant path
    exec ssh -t "${SSHO[@]}" "$TARGET" "sudo -n $AGENT_BIN shell $APP $hex"
  fi
  # shellcheck disable=SC2029 # expanded here on purpose
  # lint: allow RL04 APP passed valid_app, hex is [0-9a-f]+, AGENT_BIN is a constant path
  exec ssh "${SSHO[@]}" "$TARGET" "sudo -n $AGENT_BIN shell $APP $hex"
}
