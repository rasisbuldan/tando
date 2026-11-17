package paths

import "tando/srv/internal/run"

func F() {
	run.Cmd{Argv: []string{"/usr/bin/sh"}}
	run.Cmd{Argv: []string{"/bin/dash"}}
	run.Cmd{Argv: append([]string{"/bin/" + "zsh"}, "x")}
}
