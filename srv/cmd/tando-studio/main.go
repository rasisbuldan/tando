// tando-studio: `tando db studio`, a read-only web UI and SQL editor for an app's PostgreSQL
// database (srv/studio, docs/COMMANDS.md). Installed as /opt/tando/bin/tando-studio (root 755)
// by `tando host setup`; started only by `tando-agent db-studio`, as the app's user in a
// transient unit, on a unix socket the admin's ssh connection forwards. It starts no program
// and listens on no network port.
//
//	tando-studio serve --sock /run/tando-studio/<sid>/s --app APP --host NAME --admin USER --port N --idle MINUTES
//	tando-studio version
//
// stdout carries two lines, "ready code=... probe=... mode=ro pg=..." and "stopped reason=...
// queries=N"; stdin the client's heartbeat (a byte every 10 s; EOF ends the session).
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"syscall"
	"time"

	"tando/srv/internal/buildinfo"
	"tando/srv/internal/out"
	"tando/srv/studio"
)

func main() {
	syscall.Umask(0o077)
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "tando-studio: %s\n", out.Clean(err.Error()))
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 1 && args[0] == "version" {
		fmt.Println(buildinfo.Version)
		return nil
	}
	if len(args) == 0 || args[0] != "serve" {
		return fmt.Errorf("usage: tando-studio serve ... | version")
	}
	a, err := studio.ParseArgs(args[1:])
	if err != nil {
		return err
	}
	if os.Getenv("GOMEMLIMIT") == "" { // (the unit sets it; a hand start gets the same)
		debug.SetMemoryLimit(48 << 20)
	}
	cred := a.Cred
	if cred == "" {
		dir := os.Getenv("CREDENTIALS_DIRECTORY")
		if dir == "" {
			return fmt.Errorf("no credentials (CREDENTIALS_DIRECTORY): started outside tando-agent db-studio?")
		}
		cred = filepath.Join(dir, "db")
	}
	b, err := os.ReadFile(cred)
	if err != nil {
		return fmt.Errorf("read the credentials: %w", err)
	}
	if err := studio.ParseCred(b, &a.Cfg); err != nil {
		return err
	}
	a.Cfg.Out, a.Cfg.Log = os.Stdout, os.Stderr
	ctx, cf := context.WithTimeout(context.Background(), 15*time.Second)
	s, err := studio.New(ctx, a.Cfg)
	cf()
	if err != nil {
		return err
	}
	ln, err := studio.Listen(a.Sock)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", a.Sock, err)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	signal.Ignore(syscall.SIGPIPE)
	go func() { <-sig; s.End("signal") }()
	fmt.Fprintf(os.Stderr, "tando-studio: started for %s (%s) on %s\n", a.Cfg.App, a.Cfg.Admin, a.Sock)
	reason := s.Serve(ln, os.Stdin, time.Second)
	fmt.Fprintf(os.Stderr, "tando-studio: stopped (%s)\n", reason)
	return nil
}
