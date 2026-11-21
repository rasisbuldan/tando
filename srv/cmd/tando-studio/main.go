// tando-studio: `tando db studio`, a read-only web UI and SQL editor for the apps' PostgreSQL
// databases (srv/studio, docs/COMMANDS.md, docs/STUDIO.md). Installed as
// /opt/tando/bin/tando-studio (root 755) by `tando host setup`, which also writes
// tando-studio.service. It listens on no network port.
//
//	tando-studio service            the front (tando-studio.service): the admins' sockets, codes,
//	                                tokens; starts a helper per app and session, nothing else
//	tando-studio serve ... --fd     a helper: one app's studio, as the app's user (the front starts it)
//	tando-studio ctl <line>         the root agent's request to the front (code, revoke, ls)
//	tando-studio serve --sock /run/tando-studio/<sid>/s --app APP --host NAME --admin USER --port N --idle MINUTES
//	                                (the per-session studio of older agents and of the tests)
//	tando-studio version
//
// A helper's stdout carries "ready code=... probe=... mode=ro pg=...", "backend pid=N" and
// "stopped reason=... queries=N"; its stdin is the front's pipe (EOF ends it).
package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"strings"
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
	if len(args) >= 1 && args[0] == "service" {
		return service(args[1:])
	}
	if len(args) >= 2 && args[0] == "ctl" {
		a, err := studio.CtlRequest(runDir+"/ctl", strings.Join(args[1:], " "))
		if err != nil {
			return err
		}
		fmt.Println(a)
		if strings.HasPrefix(a, "error=") {
			os.Exit(1)
		}
		return nil
	}
	if len(args) == 0 || args[0] != "serve" {
		return fmt.Errorf("usage: tando-studio service | ctl ... | serve ... | version")
	}
	a, err := studio.ParseArgs(args[1:])
	if err != nil {
		return err
	}
	if os.Getenv("GOMEMLIMIT") == "" { // (the unit sets it; a hand start gets the same)
		debug.SetMemoryLimit(48 << 20)
	}
	if a.FD { // the service's helper: its credential is the app's env, which its user may read
		b, err := os.ReadFile(a.Env)
		if err != nil {
			return fmt.Errorf("read the env of %s: %w", a.Cfg.App, err)
		}
		if err := studio.ParseEnvCred(b, a.Cfg.App, &a.Cfg); err != nil {
			return err
		}
		return serve(a, nil)
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
	ln, err := studio.Listen(a.Sock)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", a.Sock, err)
	}
	return serve(a, ln)
}

func serve(a studio.Args, ln net.Listener) error {
	a.Cfg.Out, a.Cfg.Log = os.Stdout, os.Stderr
	ctx, cf := context.WithTimeout(context.Background(), 15*time.Second)
	s, err := studio.New(ctx, a.Cfg)
	cf()
	if err != nil {
		return err
	}
	where := a.Sock
	if ln == nil { // fd 3: the socket the front made
		f := os.NewFile(3, "listener")
		if ln, err = net.FileListener(f); err != nil {
			return fmt.Errorf("no listener on fd 3: %w", err)
		}
		f.Close()
		where = "the front's socket"
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	signal.Ignore(syscall.SIGPIPE)
	go func() { <-sig; s.End("signal") }()
	fmt.Fprintf(os.Stderr, "tando-studio: started for %s (%s) on %s\n", a.Cfg.App, a.Cfg.Admin, where)
	reason := s.Serve(ln, os.Stdin, time.Second)
	fmt.Fprintf(os.Stderr, "tando-studio: stopped (%s)\n", reason)
	return nil
}

const runDir = "/run/tando-studio"

// service: tando-studio.service's main process (root, CAP_SETUID and CAP_SETGID only)
func service(args []string) error {
	if len(args) != 0 {
		return fmt.Errorf("usage: tando-studio service")
	}
	if os.Getenv("GOMEMLIMIT") == "" {
		debug.SetMemoryLimit(16 << 20)
	}
	bin, err := os.Executable()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(runDir, 0o711); err != nil {
		return err
	}
	os.Chmod(runDir, 0o711)
	sp := &Spawner{Bin: bin, Run: runDir, Root: "/opt/tando", Lower: LowerFile(runDir)}
	svc := studio.NewService(studio.SvcConfig{Root: "/opt/tando", Run: runDir, Log: os.Stderr, Spawn: func(h *studio.Helper) error { return sp.Spawn(h) }})
	sp.Svc = svc
	ctl := runDir + "/ctl"
	os.Remove(ctl)
	ln, err := net.Listen("unix", ctl)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", ctl, err)
	}
	if err := os.Chmod(ctl, 0o600); err != nil {
		return err
	}
	stop := make(chan struct{})
	go svc.Janitor(30*time.Second, stop)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	signal.Ignore(syscall.SIGPIPE)
	go func() { <-sig; ln.Close() }()
	fmt.Fprintf(os.Stderr, "tando-studio: service started (no helper, no database connection until a studio is opened)\n")
	svc.ServeCtl(ln)
	close(stop)
	svc.Shutdown()
	fmt.Fprintf(os.Stderr, "tando-studio: service stopped\n")
	return nil
}
