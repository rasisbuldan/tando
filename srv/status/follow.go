package status

import (
	"bytes"
	"context"
	"errors"
	"io"
	"path/filepath"
	"strings"
	"time"

	"tando/srv/internal/decimal"
)

// LiveRows answers `live [app]` from tandod's fast loop (srv/live's lhost and lapp rows; main
// passes proto.AskLive). ok false: no answer (no daemon, an older one, a host without cgroup v2).
type LiveRows func(ctx context.Context, app string) (body []byte, ok bool)

// ErrNoLive: follow has no fast loop to read: the client polls status instead.
var ErrNoLive = errors.New("no live view on this server (tandod with cgroup v2 gives one): polling instead")

// Follow is `tando-status follow [app]`: frames of status rows, one every `every`, on one
// connection, until the reader goes away (a failed write) or ctx ends:
//
//	@frame <epoch>
//	<the rows of status [app]>, with the live fields of the host and app rows from the fast loop
//	<the fast loop's lhost and lapp rows>
//	loadavg <1 min> <5 min> <15 min>
//	@end
//
// The whole status is collected every `full` (or after the live rows failed); between, only the
// fast loop's latest point is read, which starts nothing and costs the daemon a copy of a few
// rows. Without a fast loop at the first frame it returns ErrNoLive before writing anything.
func (c *Collector) Follow(ctx context.Context, w io.Writer, name string, remote Remote, lv LiveRows, every, full time.Duration) error {
	var base []byte
	var baseAt int64
	var states string
	for i := 0; ; i++ {
		now := c.Env.Now().Unix()
		rows, ok := lv(ctx, name)
		if !ok {
			if i == 0 {
				return ErrNoLive
			}
			rows, baseAt = nil, 0 // (the whole status every time until it answers again)
		}
		// the whole status when it is due, and at once when a unit changed state (a stop, a start,
		// a crash: the release, the alerts and tando's own state word change with it)
		st := liveStates(rows)
		if base == nil || now-baseAt >= int64(full/time.Second) || (rows != nil && st != states) {
			var b bytes.Buffer
			err := c.StatusVia(ctx, &b, name, remote)
			if err != nil && base == nil {
				return err
			}
			if err == nil {
				base, baseAt = b.Bytes(), now
			}
		}
		states = st
		var f bytes.Buffer
		f.WriteString("@frame " + decimal.Itoa(now) + "\n")
		f.Write(Patch(base, rows, now-baseAt))
		f.Write(rows)
		// the three load averages, as `tando snapshot` reads them beside status (/proc/loadavg)
		if b, err := readBounded(filepath.Join(c.Env.Proc, "loadavg"), 4096, false); err == nil {
			if l := words(firstLine(b)); len(l) >= 3 {
				f.WriteString("loadavg\t" + l[0] + "\t" + l[1] + "\t" + l[2] + "\n")
			}
		}
		f.WriteString("@end\n")
		if _, err := w.Write(f.Bytes()); err != nil {
			return nil // the reader is gone
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(every):
		}
	}
}

// liveStates: each app's ActiveState in live rows, as one string to compare.
func liveStates(live []byte) string {
	var b strings.Builder
	for _, l := range strings.Split(string(live), "\n") {
		if f := strings.Split(l, "\t"); f[0] == "lapp" && len(f) >= 10 {
			b.WriteString(f[1] + "=" + f[3] + " ")
		}
	}
	return b.String()
}

// Patch writes status rows with the live fields of the fast loop's latest point: the server row's
// clock, the host row's
// load, memory in use, disk in use and uptime; each app row's state, memory, restarts, uptime and
// CPU (the 26th field, per mille of a core: here over the last 5 s, not the last minute). elapsed
// is how old the status rows are (their uptimes grow by it). An app that tando stopped, one being
// deployed and a static site keep the state status gave. Without live rows it is status as given.
func Patch(status, live []byte, elapsed int64) []byte {
	if len(live) == 0 {
		return status
	}
	var host []string
	apps := map[string][]string{}
	for _, l := range strings.Split(string(live), "\n") {
		f := strings.Split(l, "\t")
		switch {
		case f[0] == "lhost" && len(f) >= 8:
			host = f
		case f[0] == "lapp" && len(f) >= 10:
			apps[f[1]] = f
		}
	}
	var b bytes.Buffer
	for _, l := range bytes.SplitAfter(status, []byte("\n")) {
		if len(l) == 0 {
			continue
		}
		nl := bytes.HasSuffix(l, []byte("\n"))
		f := strings.Split(strings.TrimSuffix(string(l), "\n"), "\t")
		switch {
		case f[0] == "host" && len(f) >= 9 && host != nil:
			f[3], f[5], f[7] = host[2], host[3], host[6]
			f[8] = plus(f[8], elapsed)
		case f[0] == "server" && len(f) >= 2:
			f[1] = plus(f[1], elapsed) // (the server's clock: the client measures the skew with it)
		case f[0] == "app" && len(f) >= 13 && apps[f[1]] != nil:
			patchApp(f, apps[f[1]], elapsed)
		default:
			b.Write(l)
			continue
		}
		b.WriteString(strings.Join(f, "\t"))
		if nl {
			b.WriteByte('\n')
		}
	}
	return b.Bytes()
}

// patchApp: f an app row (AppRow), a the app's lapp row.
func patchApp(f, a []string, elapsed int64) {
	state, active := f[2], a[3]
	f[6], f[9] = a[7], a[5]
	if len(f) > 25 && a[8] != "-" {
		f[25] = a[8]
	}
	if len(a) > 10 { // the CPU time so far, in systemd's ns (tando top works out its % from it)
		if us, ok := decimal.Parse(a[10], 18); ok && us > 0 {
			f[8] = decimal.Itoa(us * 1000)
		}
	}
	if state == "stopped" || state == "deploying" || f[12] == "static" || active == "?" {
		return
	}
	f[2] = active
	switch {
	case active != "active":
		f[10] = "0"
	case state == "active":
		f[10] = plus(f[10], elapsed)
	}
}

func plus(n string, d int64) string {
	v, ok := decimal.Parse(n, 18)
	if !ok {
		return n
	}
	return decimal.Itoa(v + d)
}
