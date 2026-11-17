package watch

import (
	"os"

	"tando/srv/internal/run"
)

type W struct{ Run run.Runner }

func (w W) bin(name string) string { return "/opt/tando/bin/" + name }

func which(name string) string { return "/usr/sbin/" + name }

func (w W) F(unit string) {
	// a variable that is only a name resolved by bin/which
	logs := w.bin("tando-logs")
	nft := which("nft")
	sm := which("sendmail")
	if sm == "" {
		sm = "/usr/sbin/sendmail"
	}
	w.Run.Output(nil, run.Cmd{Argv: []string{nice, logs, "audit-write"}})
	w.Run.Output(nil, run.Cmd{Argv: []string{nft, "-f", "x"}})
	w.Run.Output(nil, run.Cmd{Argv: []string{"systemd-run", "--quiet", "--pipe", "-p", "Description=x", sm, "-t"}})
	w.Run.Output(nil, run.Cmd{Argv: append([]string{"du", "-smxc", "--"}, os.Args...)})
	// a program called "os" that is not the package
	os := struct{ StartProcess func() }{}
	os.StartProcess()
}

const nice = "nice"

type Scan struct{ bin string }

func (s Scan) F(r run.Runner) { r.Output(nil, run.Cmd{Argv: []string{"nice", s.bin, "watch-scan"}}) }
