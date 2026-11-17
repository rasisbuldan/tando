package sysprop

import "tando/srv/internal/run"

func F(app string) {
	run.Cmd{Argv: []string{"systemd-run", "-p", "ExecStartPre=/bin/sh -c id", "/opt/tando/bin/tando-agent"}}
	run.Cmd{Argv: []string{"systemd-run", "-p", "Environment=LD_PRELOAD=/tmp/x", "tando-agent"}}
	run.Cmd{Argv: []string{"systemd-run", "-E", "LD_PRELOAD=/tmp/x", "tando-agent"}}
	run.Cmd{Argv: []string{"systemd-run", "--setenv=A=b", "tando-agent"}}
	run.Cmd{Argv: []string{"systemd-run", "-p", app + "=1", "tando-agent"}}
	run.Cmd{Argv: []string{"systemd-run", "--pty", "tando-agent"}}
	run.Cmd{Argv: []string{"systemd-run", "-p", "ExecStartPost=" + app, "tando-agent"}}
	run.Cmd{Argv: []string{"sudo", "-n", "-E", "--", "tando-agent"}}
	run.Cmd{Argv: []string{"sudo", "-n", "-u", "app", "--", "tando-agent"}}
	run.Cmd{Argv: []string{"sudo", "-n", "--", "env", "x"}}
	run.Cmd{Argv: []string{"nice", "-n", app, "tando-agent"}}
}
