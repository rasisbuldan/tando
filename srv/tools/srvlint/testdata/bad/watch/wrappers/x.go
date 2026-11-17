package wrappers

import "tando/srv/internal/run"

func F() {
	run.Cmd{Argv: []string{"env", "x"}}
	run.Cmd{Argv: []string{"xargs", "x"}}
	run.Cmd{Argv: []string{"find", ".", "-exec", "x"}}
	run.Cmd{Argv: []string{"timeout", "5", "x"}}
	run.Cmd{Argv: []string{"nice", "bash"}}
	run.Cmd{Argv: []string{"systemd-run", "--quiet", "/bin/sh", "-c", "id"}}
	run.Cmd{Argv: []string{"sudo", "-n", "--", "dash"}}
}
