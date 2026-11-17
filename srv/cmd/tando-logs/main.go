// tando-logs: the logging side of tando on the server (docs/LOGGING.md). Installed as
// /opt/tando/bin/tando-logs (root 755) next to tando-agent, which calls it; tando-watch runs
// watch-scan once a minute. See package tando/srv/logs.
//
//	tando-logs logs <app> spec               query the app's log; the query as key=value lines on stdin
//	tando-logs logs <app> [n] [follow]       the old form (last n lines, optionally following)
//	tando-logs log-stats [app]               log disk use and lines/bytes per hour over 24 h (cached)
//	tando-logs req-summary <app> <secs>      one pass over the request log of a window
//	tando-logs req-roll [app]                bring the request index up to date (watch-scan does it too)
//	tando-logs req-tail <app> <n> [follow]   newest requests
//	tando-logs req-errors <app> <secs> <n> [4xx]
//	tando-logs watch-scan [app...]           incremental error and request scan: the monitor's (it consumes the events)
//	tando-logs errors <app> <secs> [n]       error groups seen in the window, with samples
//	tando-logs audit-read [app] [n]          audit rows;  audit-write <verb> <app> <rc> [note];  audit-origin
//	tando-logs host-setup [k=v...]           host defaults, main journal cap, directories
//	tando-logs app-setup <app> | app-remove <app> | unit-props <app> | caddy-log <app> | valid <key> <value>
//	tando-logs log-doctor                    check rows for `tando doctor`
//	tando-logs version                       the tando version it was built from
package main

import (
	"context"
	"fmt"
	"os"
	"runtime/debug"
	"syscall"

	"tando/srv/internal/buildinfo"
	"tando/srv/internal/env"
	"tando/srv/internal/out"
	"tando/srv/logs"
)

func main() {
	syscall.Umask(0o022) // new directories 755, files as each write asks, whatever umask sudo passed on
	// a small server runs this next to the apps: the collector keeps the heap near what is live
	// (a few MB: buffers, a segment's path keys) instead of letting it double first
	debug.SetGCPercent(20)
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "tando-logs: %v\n", err)
		os.Exit(1)
	}
}

func arg(a []string, i int) string {
	if i < len(a) {
		return a[i]
	}
	return ""
}

func run(args []string) error {
	verb := arg(args, 0)
	if len(args) > 0 {
		args = args[1:]
	}
	ctx := context.Background()
	l := logs.New(env.OS())
	l.Getenv, l.PPID = os.Getenv, os.Getppid() // (the environment is read here, not in the package)
	l.Trim = debug.FreeOSMemory
	l.LimitCPU = logs.LimitProcessCPU // (a one-shot: the limit is this process's)
	w := out.NewSize(os.Stdout, 64<<10)
	var err error
	switch verb {
	case "logs":
		err = l.Query(ctx, arg(args, 0), args[min(1, len(args)):], os.Stdin, w.Stream())
	case "log-stats":
		err = l.LogStats(ctx, arg(args, 0), w)
	case "log-doctor":
		l.LogDoctor(ctx, w)
	case "req-summary":
		err = l.ReqSummary(ctx, arg(args, 0), arg(args, 1), w)
	case "req-roll":
		err = l.ReqRoll(ctx, arg(args, 0), w)
	case "req-tail":
		err = l.ReqTail(ctx, arg(args, 0), arg(args, 1), arg(args, 2), w, w.Flush)
	case "req-errors":
		err = l.ReqErrors(ctx, arg(args, 0), arg(args, 1), arg(args, 2), arg(args, 3), w)
	case "watch-scan":
		err = l.WatchScan(ctx, args, w)
	case "errors":
		err = l.Errors(ctx, arg(args, 0), arg(args, 1), arg(args, 2), w)
	case "audit-read":
		err = l.AuditRead(arg(args, 0), arg(args, 1), w)
	case "audit-write":
		err = l.AuditWrite(ctx, args)
	case "audit-origin":
		l.AuditOrigin(w)
	case "host-setup":
		err = l.HostSetup(ctx, args, w)
	case "app-setup":
		err = l.AppSetup(ctx, arg(args, 0), w)
	case "app-remove":
		err = l.AppRemove(ctx, arg(args, 0), w)
	case "unit-props":
		err = l.UnitProps(arg(args, 0), w.Stream())
	case "caddy-log":
		err = l.CaddyLog(ctx, arg(args, 0), w.Stream())
	case "valid":
		err = logs.CheckValue(arg(args, 0), arg(args, 1))
	case "version":
		w.Row(buildinfo.Version)
	default:
		err = fmt.Errorf("unknown verb: %s", verb)
	}
	// what was printed before a failure goes out first, as the shell's output did
	ferr := w.Flush()
	if err != nil {
		return err
	}
	return ferr
}
