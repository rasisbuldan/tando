package methodvalue

import "tando/srv/internal/run"

func F(r run.Runner) {
	f := r.Output
	f(nil, run.Cmd{Argv: []string{"systemctl"}})
}
