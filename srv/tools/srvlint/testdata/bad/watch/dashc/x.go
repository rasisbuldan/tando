package dashc

import "tando/srv/internal/run"

const shell = "dash"

func F() {
	run.Cmd{Argv: []string{"bash5", "-lc", "id"}}
	run.Cmd{Argv: []string{shell, "-ec", "id"}}
}
