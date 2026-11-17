package othershells

import "tando/srv/internal/run"

func F() {
	for _, s := range [][]string{{"ash"}, {"mksh"}, {"yash"}, {"posh"}, {"fish"}, {"csh"}, {"tcsh"}, {"rbash"}, {"busybox", "sh"}} {
		run.Cmd{Argv: s}
	}
	run.Cmd{Argv: []string{"ash"}}
	run.Cmd{Argv: []string{"mksh"}}
	run.Cmd{Argv: []string{"yash"}}
	run.Cmd{Argv: []string{"posh"}}
	run.Cmd{Argv: []string{"fish"}}
	run.Cmd{Argv: []string{"csh"}}
	run.Cmd{Argv: []string{"tcsh"}}
	run.Cmd{Argv: []string{"rbash"}}
}
