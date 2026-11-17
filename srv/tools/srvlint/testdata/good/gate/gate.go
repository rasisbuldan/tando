package gate

import (
	"syscall"

	"tando/srv/internal/run"
)

const sysFstatat = syscall.SYS_FSTATAT

type Paths struct{ Agent, Gate string }

type Gate struct {
	P   Paths
	Run run.Runner
}

func (g *Gate) quiet(args ...string) { g.Run.Output(nil, run.Cmd{Argv: args}) }

func (g *Gate) F(app string) {
	g.quiet("systemctl", "reset-failed", "--", app)
	g.quiet("getent", "passwd", "--", app)
	g.Run.Output(nil, run.Cmd{Argv: append([]string{g.P.Agent}, "begin", app)})
	g.Run.Output(nil, run.Cmd{Argv: []string{"sudo", "-n", "--", g.P.Gate, "root", app}})
	argv := []string{"systemd-run", "--quiet", "--unit=u-" + app, "-p", "Description=x", "--", g.P.Gate, "rx", app}
	argv = append(argv, "more")
	g.Run.Output(nil, run.Cmd{Argv: argv})
	g.Run.Output(nil, run.Cmd{Argv: []string{"/usr/bin/rsync", "--server"}})
}
