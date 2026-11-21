// tando-status: the read-only, frequently called verbs of tando-agent, in Go. Installed as
// /opt/tando/bin/tando-status (root 755) by `tando host setup`; tando-agent execs it for these
// verbs (and keeps its shell versions as the fallback while the binary is missing). See package
// tando/srv/status. The output and the error messages are the agent's ("tando-agent: ...").
//
//	tando-status status [app]           host row, app rows; with an app its releases, history, domains, metrics
//	tando-status follow [app]           status as frames every 5 s with tandod's live rows (root; status.Follow)
//	tando-status live|ring [app]        tandod's fast loop: the latest point, the last hour (root; tests, debugging)
//	tando-status deploy-status <app> <id>
//	tando-status releases <app>
//	tando-status history [app] [n]
//	tando-status busy <app>             (root)
//	tando-status info
//	tando-status version                the tando version it was built from
//
// TANDO_STATUS_TRACE=1 says on stderr whether status was answered by tandod (tests).
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"runtime/debug"
	"syscall"
	"time"

	"tando/srv/daemon/proto"
	"tando/srv/internal/buildinfo"
	"tando/srv/internal/env"
	"tando/srv/internal/out"
	"tando/srv/status"
)

var errUsage = errors.New("usage: tando-status status [app] | follow [app] | deploy-status <app> <id> | releases <app> | history [app] [n] | busy <app> | info | version")

func main() {
	syscall.Umask(0o022) // (a recreated releases/ is 755 whatever umask sudo passed on)
	// A run lives for milliseconds and allocates a few hundred KB per app: no collection below
	// 32 MB, so most runs never collect (a long-running caller sets its own).
	debug.SetGCPercent(-1)
	debug.SetMemoryLimit(32 << 20)
	if err := run(os.Args[1:]); err != nil {
		// the agent's verbs: its words, which the client turns into "tando: ..." and matches
		who := "tando-agent"
		if err == errUsage {
			who = "tando-status"
		}
		fmt.Fprintf(os.Stderr, "%s: %s\n", who, out.Clean(err.Error()))
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
	verb, args := arg(args, 0), args[min(1, len(args)):]
	c := status.New(env.OS())
	c.Stderr = os.Stderr
	c.SudoUser = os.Getenv("SUDO_USER")
	c.AgentEnv = status.AgentEnv(os.LookupEnv)
	if os.Getenv("TANDO_STATUS_TRACE") == "1" {
		c.Trace = os.Stderr
	}
	ctx := context.Background()
	w := os.Stdout // (each verb writes its finished output at once: status/verb_status.go, sink)
	switch verb {
	case "status":
		return c.StatusVia(ctx, w, arg(args, 0), proto.AskStatus)
	case "follow":
		// (status every minute, the fast loop's point every 5 s: package status, follow.go); it
		// runs for as long as someone watches, so the collector is on again
		debug.SetGCPercent(100)
		return c.Follow(ctx, w, arg(args, 0), proto.AskStatus, proto.AskLive, 5*time.Second, time.Minute)
	case "live", "ring":
		var a []string
		if arg(args, 0) != "" {
			a = []string{arg(args, 0)}
		}
		r, err := proto.FromArgs(verb, a)
		if err != nil {
			return errUsage
		}
		ans, err := proto.Call(ctx, proto.Socket, r, 100*time.Millisecond, 10*time.Second)
		if err != nil {
			return err
		}
		if !ans.OK {
			return errors.New(ans.Err)
		}
		_, err = w.Write(ans.Body)
		return err
	case "deploy-status":
		return c.DeployStatus(ctx, w, arg(args, 0), arg(args, 1))
	case "releases":
		return c.Releases(ctx, w, arg(args, 0))
	case "history":
		return c.History(ctx, w, arg(args, 0), arg(args, 1))
	case "busy":
		return c.Busy(ctx, w, arg(args, 0))
	case "info":
		return c.Info(ctx, w)
	case "version":
		_, err := fmt.Fprintln(w, buildinfo.Version)
		return err
	}
	return errUsage
}
