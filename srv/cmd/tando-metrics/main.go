// tando-metrics: per-minute samples of every tando app, for graphs (tando top, tando status).
// Installed as /opt/tando/bin/tando-metrics (root 755) by `tando host setup`; `sample` runs from
// tando-watch.service once a minute (ExecStartPre). See package tando/srv/metrics.
//
//	tando-metrics sample                                append one line per app and one for the host
//	tando-metrics read <app|host> <points> <bucket seconds>   the last <points> buckets, averaged
//	tando-metrics read host.x|tandod.x <points> <bucket>     the host's extended series, what the
//	                                                    monitoring costs (named columns)
//	tando-metrics version                               the tando version it was built from
//
// TANDO_METRICS_DIR replaces /var/lib/tando/metrics (tests).
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"syscall"

	"tando/srv/internal/buildinfo"
	"tando/srv/internal/env"
	"tando/srv/internal/out"
	"tando/srv/metrics"
)

const usage = "usage: tando-metrics sample | read <app|host|host.x|tandod.x> <points> <bucket seconds> | version"

func main() {
	syscall.Umask(0o022) // files are 644 and the directory 755 whatever umask sudo passed on
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "tando-metrics: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	verb := ""
	if len(args) > 0 {
		verb, args = args[0], args[1:]
	}
	m := metrics.New(env.OS(), os.Getenv("TANDO_METRICS_DIR"))
	w := out.New(os.Stdout)
	switch verb {
	case "sample":
		return m.Sample(context.Background())
	case "read":
		a, err := metrics.ParseReadArgs(args)
		if err != nil {
			return err
		}
		m.Read(w, a)
	case "version":
		w.Row(buildinfo.Version)
	default:
		return errors.New(usage)
	}
	return w.Flush()
}
