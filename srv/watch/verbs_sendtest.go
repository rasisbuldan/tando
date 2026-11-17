package watch

import (
	"context"
	"os"
	"sync"

	"tando/srv/internal/out"
)

// TestSend is the verb `test [name]`: a test message through each notifier now, in parallel; one
// row per notifier. A notifier that works again retries its queue on the next run instead of
// after its backoff.
func (w Watch) TestSend(ctx context.Context, o *out.Writer, args []string) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	now := w.now()
	cfg := loadSettings(w.Conf)
	mkdir700(w.RunDir)
	// (composed from a queued line, as the shell did, for the host name and the events)
	tmp, err := os.CreateTemp(w.RunDir, "msg.")
	if err != nil {
		return err
	}
	tmp.WriteString(message{"test", "host", "test", "this is a test message from tando alerts; delivery works", now}.line())
	tmp.Close()
	m := w.compose(cfg, []string{tmp.Name()})
	os.Remove(tmp.Name())
	m.title = "tando " + m.host + ": test"
	m.text = m.title + "\nThis is a test message from tando alerts: delivery works."
	o.Row("sent", m.title, m.body())
	only := arg(args, 0)
	type res struct {
		name, r string
		ok      bool
	}
	var rs []res
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, n := range w.notifiers() {
		if only != "" && n != only {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, err := w.notifier(n).Send(ctx, m)
			if err != nil {
				r = errText(err)
			}
			mu.Lock()
			rs = append(rs, res{n, r, err == nil})
			mu.Unlock()
		}()
	}
	wg.Wait()
	l, err := w.lockBusy()
	if err != nil {
		o.Flush()
		return err
	}
	defer l.Release()
	st := newStore(loadQuiet(w.statePath()))
	sortBy(rs, func(r res) string { return r.name })
	for _, r := range rs {
		if r.ok {
			o.Row("test", r.name, "ok", r.r)
			st.del("_nf." + r.name + ".next")
		} else {
			o.Row("test", r.name, "fail", r.r)
		}
	}
	if st.dirty {
		st.save(w.statePath())
	}
	if only != "" && len(rs) == 0 {
		o.Flush()
		return errf("no such notifier: %s", only)
	}
	if len(rs) == 0 {
		o.KV("none", "1")
	}
	return nil
}

// sortBy sorts s by key (stable, byte order).
func sortBy[T any](s []T, key func(T) string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && key(s[j]) < key(s[j-1]); j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}
