// tando-watch: the alert checks of a tando host and the delivery of their notifications. Installed
// as /opt/tando/bin/tando-watch (root 755) by `tando host setup`; `run` is started once a minute
// by tando-watch.timer. See package tando/srv/watch and docs/MONITORING.md.
//
//	tando-watch run                       one check run (tandod runs it when it runs; else here)
//	tando-watch install | uninstall       the timer units, directories and settings file
//	tando-watch show [n]                  everything tando alerts shows (n history lines, 8)
//	tando-watch history [n]               the last n transitions (50)
//	tando-watch doctor                    rows for tando doctor (no root needed)
//	tando-watch brief [app]               firing and pending alerts for tando status (no root)
//	tando-watch health [app]              uptime and incidents for tando health
//	tando-watch forget <app>              drop an app's alert state (tando destroy)
//	tando-watch set                       key=value lines on stdin
//	tando-watch notifier-add <name> <type>   fields as key=value lines on stdin (secrets)
//	tando-watch notifier-rm <name>
//	tando-watch heartbeat                 "url=<url>" or "off" on stdin
//	tando-watch silence <app|all> <seconds>
//	tando-watch test [name]               a test message through each notifier
//	tando-watch version                   the tando version it was built from
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"syscall"

	"tando/srv/daemon/proto"
	"tando/srv/internal/buildinfo"
	"tando/srv/internal/env"
	"tando/srv/internal/out"
	"tando/srv/watch"
)

func main() {
	syscall.Umask(0o022) // new directories 755, as the shell version's `umask 022`
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "tando-watch: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	verb := ""
	if len(args) > 0 {
		verb, args = args[0], args[1:]
	}
	ctx := context.Background()
	w := watch.New(env.OS(), os.Getpid())
	o := out.New(os.Stdout)
	// tandod, when it runs, answers the read verbs from its cache and runs `run` itself (one
	// tick at a time); when nothing answers (not running, not root, an old server) the verb runs
	// here, as before. A request the socket does not carry also runs here, so every message is
	// the same (proto.AskWatch has the list and the timeouts).
	if verb == "run" { // (arguments ignored, as the shell version did)
		// tandod's tick, or this one's when it does not answer: one budget for both (proto.RunTick)
		return proto.RunTick(ctx, watch.TickTimeout, w.Run)
	}
	if a, ok := proto.AskWatch(ctx, verb, args); ok {
		o.Relay(a.Body) // (rows tandod's out.Writer made)
		o.Flush()       // (as before, a failed write of a relayed answer is not an error)
		if !a.OK {
			return errors.New(a.Err)
		}
		return nil
	}
	var err error
	switch verb {
	case "install":
		err = w.Install(ctx, o)
	case "uninstall":
		err = w.Uninstall(ctx, o)
	case "doctor":
		w.Doctor(ctx, o)
	case "brief":
		w.Brief(o, args)
	case "health":
		err = w.Health(o, args)
	case "forget":
		err = w.Forget(o, args)
	case "show":
		err = w.Show(ctx, o, args)
	case "history":
		err = w.History(o, args)
	case "set":
		err = w.Set(o, os.Stdin)
	case "notifier-add":
		err = w.NotifierAdd(o, args, os.Stdin)
	case "notifier-rm":
		err = w.NotifierRm(o, args)
	case "heartbeat":
		err = w.Heartbeat(o, os.Stdin)
	case "silence":
		err = w.Silence(o, args)
	case "test":
		err = w.TestSend(ctx, o, args)
	case "version":
		o.Row(buildinfo.Version)
	default:
		err = fmt.Errorf("unknown verb: %s", verb)
	}
	// what was printed before an error is kept (test prints its rows, then "no such notifier")
	if ferr := o.Flush(); err == nil {
		err = ferr
	}
	return err
}
