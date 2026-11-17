package daemon

import (
	"context"
	"io"

	"tando/srv/internal/out"
	"tando/srv/logs"
	"tando/srv/metrics"
	"tando/srv/watch"
)

// statusRows gives the status Collector the rows it would otherwise start tando-logs log-stats,
// tando-watch brief and tando-metrics read for: the same functions those programs run, here
// in-process, so a status answered by the daemon starts no program (srv/status rows.go).
func statusRows(d *Daemon) {
	l := *d.Logs
	l.Stderr = io.Discard // (the one-shot's per-app warnings went to /dev/null too)
	d.Status.LogRows = logRows{&l}
	d.Status.AlertRows = alertRows{d.Watch}
	d.Status.TrendRows = trendRows{d.Metrics}
}

type logRows struct{ l *logs.Logs }

func (r logRows) LogStats(ctx context.Context, app string, w io.Writer) {
	o := out.New(w)
	r.l.LogStats(ctx, app, o)
	o.Flush()
}

type alertRows struct{ w watch.Watch }

func (r alertRows) Brief(ctx context.Context, app string, w io.Writer) {
	o := out.New(w)
	var args []string
	if app != "" {
		args = []string{app}
	}
	r.w.Brief(o, args)
	o.Flush()
}

type trendRows struct{ m metrics.Metrics }

func (r trendRows) Trend(ctx context.Context, app string, w io.Writer) {
	a, err := metrics.ParseReadArgs([]string{app, "16", "60"})
	if err != nil {
		return
	}
	o := out.New(w)
	r.m.Read(o, a)
	o.Flush()
}
