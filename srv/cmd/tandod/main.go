// tandod: the monitoring daemon of a tando host (package tando/srv/daemon). Installed as
// /opt/tando/bin/tandod (root 755) and run by tandod.service (`tando-watch install` writes it).
//
//	tandod            run until SIGTERM
//	tandod version    the tando version it was built from
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"runtime/debug"
	"syscall"

	"tando/srv/daemon"
	"tando/srv/internal/buildinfo"
	"tando/srv/internal/env"
)

func main() {
	syscall.Umask(0o022)
	if len(os.Args) > 1 {
		if os.Args[1] == "version" {
			fmt.Println(buildinfo.Version)
			return
		}
		fmt.Fprintln(os.Stderr, "usage: tandod [version]")
		os.Exit(1)
	}
	// light by default (the unit sets the same): collect early, a soft limit well under the
	// unit's MemoryMax
	if os.Getenv("GOGC") == "" {
		debug.SetGCPercent(50)
	}
	if os.Getenv("GOMEMLIMIT") == "" {
		debug.SetMemoryLimit(20 << 20)
	}
	e := env.OS()
	if e.EUID != 0 {
		fmt.Fprintln(os.Stderr, "tandod: this needs root")
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	stopProfile := startProfile() // (TANDOD_PROFILE: profile.go)
	defer stopProfile()
	sd := daemon.Systemd{NotifySocket: os.Getenv("NOTIFY_SOCKET"), WatchdogUSec: os.Getenv("WATCHDOG_USEC"),
		WatchdogPID: os.Getenv("WATCHDOG_PID")}
	if err := daemon.New(e, sd).Run(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "tandod: %v\n", err)
		stop()
		stopProfile()
		os.Exit(1)
	}
}
