package elemwrite2

import (
	"os"

	"tando/srv/internal/run"
)

func F(r run.Runner, i int) {
	a := []string{"systemctl", "x"}
	a[i] = os.Getenv("Y")
	r.Output(nil, run.Cmd{Argv: a})
	b := []string{"systemctl"}
	copy(b, os.Args)
	r.Output(nil, run.Cmd{Argv: b})
	c := []string{"systemctl"}
	p := &c
	(*p)[0] = "x"
	r.Output(nil, run.Cmd{Argv: c})
	d := run.Cmd{Argv: []string{"systemctl"}}
	d.Argv[0] = os.Getenv("Z")
	r.Output(nil, d)
}
