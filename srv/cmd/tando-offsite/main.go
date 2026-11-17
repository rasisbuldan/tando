// tando-offsite: copies every backup to S3-compatible object storage (Cloudflare R2, AWS S3,
// Backblaze B2, MinIO), encrypted on the server. Installed as /opt/tando/bin/tando-offsite (root
// 755) by `tando host setup`; the agent starts `push` after each backup, tando-offsite.timer runs
// `sync`; the client calls the rest over ssh with sudo. See package tando/srv/offsite and
// docs/BACKUP.md.
//
//	tando-offsite set                      settings on stdin (key=value), checked, then saved
//	tando-offsite test | status | off | sync [now] | doctor | hosts | version
//	tando-offsite push <app> <backup id>   upload one backup (the agent, in a unit of its own)
//	tando-offsite fetch <app> <backup id> [host id]   bring one back to /var/backups/tando
//	tando-offsite ls <app> [host id]       the app's backups in the bucket
//	tando-offsite brief [app]              per app: ok, pending, late, failing or off
//	tando-offsite key-show | key-saved | key-import (key on stdin) | key-rotate
//	tando-offsite dr-plan <host id> [app...] | dr-conf <host id> <app> | dr-env <host id> <app>
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"tando/srv/internal/buildinfo"
	"tando/srv/internal/env"
	"tando/srv/internal/out"
	"tando/srv/offsite"
)

const usage = "usage: tando-offsite set | test | status | off | sync | doctor | hosts | push <app> <id> | " +
	"fetch <app> <id> [host] | ls <app> [host] | brief [app] | key-show | key-saved | key-import | key-rotate | " +
	"dr-plan <host> [app...] | dr-conf <host> <app> | dr-env <host> <app> | version"

func main() {
	syscall.Umask(0o077) // backups, keys, credentials: root's alone unless a file says otherwise
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, os.Args[1:])
	stop()
	if err != nil {
		fmt.Fprintf(os.Stderr, "tando-offsite: %s\n", out.Clean(err.Error()))
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	verb := ""
	if len(args) > 0 {
		verb, args = args[0], args[1:]
	}
	o := offsite.New(env.OS(), buildinfo.Version)
	w := out.New(os.Stdout)
	defer w.Flush()
	arg := func(i int) string {
		if i < len(args) {
			return args[i]
		}
		return ""
	}
	n := func(lo, hi int) error {
		if len(args) < lo || len(args) > hi {
			return errors.New(usage)
		}
		return nil
	}
	var err error
	switch verb {
	case "set":
		if err = n(0, 0); err == nil {
			err = o.Set(ctx, w, os.Stdin)
		}
	case "test":
		if err = n(0, 0); err == nil {
			err = o.Test(ctx, w)
		}
	case "status":
		if err = n(0, 0); err == nil {
			err = o.Status(ctx, w)
		}
	case "off":
		if err = n(0, 0); err == nil {
			err = o.Off(ctx, w)
		}
	case "sync":
		if err = n(0, 1); err == nil && (arg(0) == "" || arg(0) == "now") {
			err = o.Sync(ctx, w, arg(0) == "now")
		} else if err == nil {
			err = errors.New(usage)
		}
	case "doctor":
		if err = n(0, 0); err == nil {
			err = o.Doctor(ctx, w)
		}
	case "hosts":
		if err = n(0, 0); err == nil {
			err = o.Hosts(ctx, w)
		}
	case "push":
		if err = n(2, 2); err == nil {
			err = o.Push(ctx, w, arg(0), arg(1))
		}
	case "fetch":
		if err = n(2, 3); err == nil {
			err = o.Fetch(ctx, w, arg(0), arg(1), arg(2))
		}
	case "ls":
		if err = n(1, 2); err == nil {
			err = o.Ls(ctx, w, arg(0), arg(1))
		}
	case "brief":
		if err = n(0, 1); err == nil {
			err = o.Brief(w, arg(0))
		}
	case "key-show":
		err = o.KeyShow(w)
	case "key-saved":
		err = o.KeySaved(w)
	case "key-import":
		err = o.KeyImport(w, os.Stdin)
	case "key-rotate":
		err = o.KeyRotate(w)
	case "dr-plan":
		if err = n(1, 100); err == nil {
			err = o.DrPlan(ctx, w, arg(0), args[1:])
		}
	case "dr-conf":
		if err = n(2, 2); err == nil {
			err = o.DrConf(ctx, w, arg(0), arg(1))
		}
	case "dr-env":
		if err = n(2, 2); err == nil {
			err = o.DrEnv(ctx, w, arg(0), arg(1))
		}
	case "version":
		w.Row(buildinfo.Version)
	default:
		err = errors.New(usage)
	}
	return err
}
