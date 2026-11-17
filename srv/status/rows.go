package status

import (
	"bytes"
	"context"
	"io"
)

// The rows status takes from the other tando programs. By default (nil) they are those programs'
// output: tando-logs log-stats, tando-watch brief, tando-metrics read, each started once. A
// long-running caller that has those packages in-process (tandod) supplies them instead and
// starts nothing; status itself imports none of them (srv/README.md, layers).

// LogRows writes what `tando-logs log-stats [app]` prints ("" app: every app).
type LogRows interface {
	LogStats(ctx context.Context, app string, w io.Writer)
}

// AlertRows writes what `tando-watch brief [app]` prints.
type AlertRows interface {
	Brief(ctx context.Context, app string, w io.Writer)
}

// TrendRows writes what `tando-metrics read <app> 16 60` prints.
type TrendRows interface {
	Trend(ctx context.Context, app string, w io.Writer)
}

func (c *Collector) logStatsOut(ctx context.Context, name string) []byte {
	if c.LogRows != nil {
		var b bytes.Buffer
		c.LogRows.LogStats(ctx, name, &b)
		return b.Bytes()
	}
	argv := []string{c.bin("tando-logs"), "log-stats"}
	if name != "" {
		argv = append(argv, name)
	}
	return c.output(ctx, io.Discard, argv...)
}

func (c *Collector) briefOut(ctx context.Context, name string) []byte {
	if c.AlertRows != nil {
		var b bytes.Buffer
		c.AlertRows.Brief(ctx, name, &b)
		return b.Bytes()
	}
	argv := []string{c.bin("tando-watch"), "brief"}
	if name != "" {
		argv = append(argv, name)
	}
	return c.output(ctx, c.stderr(), argv...)
}

func (c *Collector) trendOut(ctx context.Context, name string) []byte {
	if c.TrendRows != nil {
		var b bytes.Buffer
		c.TrendRows.Trend(ctx, name, &b)
		return b.Bytes()
	}
	return c.output(ctx, io.Discard, c.bin("tando-metrics"), "read", name, "16", "60")
}
