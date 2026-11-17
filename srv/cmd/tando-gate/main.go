// tando-gate: restricted deploys for CI (docs/CI.md). Installed as /opt/tando/bin/tando-gate
// (root, 755); the login shell of every deploy user tando-d-<app>. See package tando/srv/gate.
//
//	tando-gate -c "<gate> key <id>"    key mode: sshd runs the login shell with a key's forced command
//	tando-gate root <app> <verb>       root mode, through the deploy user's sudo rule
//	tando-gate rx <app> <options>      the rsync receiver, inside its systemd unit
//	tando-gate admin <verb> [<app>]    install, key-add, key-ls, key-revoke, receive, remove (root)
//	tando-gate version                 the tando version it was built from
package main

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"runtime/debug"
	"strings"
	"syscall"

	"tando/srv/gate"
	"tando/srv/internal/buildinfo"
	"tando/srv/internal/env"
)

const noShell = "tando-gate: a deploy key runs tando deploy commands only (no shell)"

func main() {
	debug.SetTraceback("none") // a crash shows no internals to a deploy key
	runtime.GOMAXPROCS(1)      // nothing here runs in parallel; fewer threads (the rx unit allows 16 tasks)
	syscall.Umask(0o022)       // files and directories as the shell version made them, whatever sudo passed on
	os.Chdir("/")              // nothing depends on the caller's working directory
	environ := os.Environ()
	c := gate.TakeEnv(environ, os.Getuid(), os.Geteuid())
	os.Clearenv() // what the gate needs is in c; children get a fixed environment (run.BaseEnv)
	os.Setenv("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
	os.Setenv("LC_ALL", "C")
	os.Exit(run(os.Args[1:], c, environ))
}

func run(args []string, c gate.Caller, environ []string) (code int) {
	defer func() {
		if recover() != nil {
			fmt.Fprintln(os.Stderr, "tando-gate: internal error")
			code = 1
		}
	}()
	if bad := gate.UnsafeRuntimeEnv(environ); c.EUID == 0 && len(bad) > 0 {
		fmt.Fprintf(os.Stderr, "tando-gate: refusing to run as root with %s set\n", strings.Join(bad, ", "))
		return 1
	}
	verb := ""
	if len(args) > 0 {
		verb = args[0]
	}
	g := gate.New(env.OS(), c)
	var err error
	switch verb {
	// lint: allow RL16 sshd starts the login shell as "<shell> -c <forced command>"
	case "-c":
		err = g.Key(args)
	case "root":
		err = g.Root(args[1:])
	case "rx":
		err = g.Rx(args[1:])
	case "admin":
		err = g.Admin(args[1:])
	case "version":
		if len(args) == 1 {
			fmt.Println(buildinfo.Version)
			return 0
		}
		fmt.Fprintln(os.Stderr, noShell)
		return 1
	default:
		fmt.Fprintln(os.Stderr, noShell)
		return 1
	}
	if err == nil {
		return 0
	}
	var ex gate.Exit
	if errors.As(err, &ex) {
		return ex.Code
	}
	fmt.Fprintf(os.Stderr, "tando-gate: %v\n", err)
	return 1
}
