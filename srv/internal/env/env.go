// Package env holds what a server program takes from the machine: its paths, the clock, who runs
// it and how commands run. main builds one with OS(); tests build their own over a temp
// directory with a fixed clock and a fake Runner. Nothing else reads globals.
//
// Layer: internal. It imports internal/run; never a domain package or daemon.
package env

import (
	"os"
	"time"

	"tando/srv/internal/run"
)

// Env is passed by value to the domain packages.
type Env struct {
	Root   string // /opt/tando: apps/<app>/{app.conf,state}, host.conf, bin/
	Lib    string // /var/lib/tando: metrics/, watch/, logscan/
	Cgroup string // /sys/fs/cgroup
	Proc   string // /proc
	EUID   int    // effective uid (0: root)
	Now    func() time.Time
	Run    run.Runner
}

// OS is the real machine.
func OS() Env {
	return Env{
		Root:   "/opt/tando",
		Lib:    "/var/lib/tando",
		Cgroup: "/sys/fs/cgroup",
		Proc:   "/proc",
		EUID:   os.Geteuid(),
		Now:    time.Now,
		Run:    run.Exec{},
	}
}
