package watch

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/lock"
)

// deliverResult is one notifier's (or the heartbeat's) attempt of this run.
type deliverResult struct {
	name string // "" for the heartbeat
	ok   bool
	why  string
}

// deliver sends the queued messages: every notifier in parallel, one attempt per run (a
// notifier in backoff waits for its time), each with its 15 s limit, then the heartbeat. It runs
// outside the run's lock, so `tando alerts set` and the next run need not wait for a slow
// receiver; a lock of its own keeps two deliveries (a run started by hand during the timer's)
// from sending the same queue twice. The results go back into the state under the run's lock.
func (w Watch) deliver(ctx context.Context, cfg settings, vs *store, now int64) {
	mkdir700(filepath.Join(w.Dir, "out"))
	dl, err := lock.Acquire(filepath.Join(w.Dir, "out", ".lock"), 0)
	if err != nil {
		return // another run is delivering: what this one queued goes with the next
	}
	defer dl.Release()
	res := w.sendAll(ctx, cfg, vs, newStore(loadQuiet(w.statePath())), now)
	if len(res) == 0 {
		return
	}
	l, err := w.takeLock(30 * time.Second)
	if err != nil {
		return
	}
	defer l.Release()
	w.recordResults(res, vs, now)
}

// sendAll makes this run's attempts at once and waits for them: each notifier with a queue that
// is not in backoff (st: the state as it was read), and the heartbeat when it is due.
func (w Watch) sendAll(ctx context.Context, cfg settings, vs, st *store, now int64) []deliverResult {
	names := w.notifiers()
	var res []deliverResult
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, n := range names {
		q := w.queued(n)
		// (wall time, kept across reboots: a backoff more than its longest (1 h) ahead is a clock
		// stepped back, and is over)
		if next := st.n("_nf."+n+".next", 0); len(q) == 0 || (next > now && next-now <= 3600) {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			m := w.compose(cfg, q)
			why, err := w.notifier(n).Send(ctx, m)
			r := deliverResult{name: n, ok: err == nil, why: why}
			if err != nil {
				r.why = errText(err)
			} else {
				removeRead(m.read)
			}
			mu.Lock()
			res = append(res, r)
			mu.Unlock()
		}()
	}
	// heartbeat: an outside "dead man's switch" URL pinged after a completed run, unless every
	// notifier has been failing for 30 min (then the silence itself is the alarm)
	hbf := filepath.Join(w.Sec, "heartbeat")
	if fsinfo.RegularFollow(hbf) {
		quiet := len(names) > 0
		for _, n := range names {
			if s := st.get("_nf." + n + ".since"); s == "" || now-num(s, 0) < 1800 {
				quiet = false
			}
		}
		if !quiet && now-vs.n("hb", 0) >= cfg.num("heartbeat_every", "")*60-5 {
			hb, _ := kvfile.Load(hbf)
			wg.Add(1)
			go func() {
				defer wg.Done()
				err := w.Send.Ping(ctx, hb["url"])
				mu.Lock()
				res = append(res, deliverResult{ok: err == nil})
				mu.Unlock()
			}()
		}
	}
	wg.Wait()
	return res
}

// recordResults writes the attempts' outcome into the state, read again under the run's lock:
// a notifier's success clears its failures, a failure counts and sets its backoff; the
// heartbeat's time goes into vs.
func (w Watch) recordResults(res []deliverResult, vs *store, now int64) {
	st := newStore(loadQuiet(w.statePath()))
	for _, r := range res {
		if r.name == "" {
			if r.ok {
				vs.set("hb", decimal.Itoa(now))
				st.del("_hb.err")
			} else {
				st.set("_hb.err", decimal.Itoa(now))
			}
			continue
		}
		p := "_nf." + r.name + "."
		if r.ok {
			st.set(p+"ok", decimal.Itoa(now))
			st.del(p+"fails", p+"next", p+"err", p+"since")
			continue
		}
		fails := st.n(p+"fails", 0) + 1
		st.set(p+"fails", decimal.Itoa(fails))
		st.set(p+"err", clean(r.why))
		st.set(p+"since", st.or(p+"since", decimal.Itoa(now)))
		st.set(p+"next", decimal.Itoa(now+backoff(fails)-5))
	}
	if st.dirty {
		st.save(w.statePath())
	}
}

// backoff after the n-th failure in a row: 1, 2, 4, ... 60 minutes.
func backoff(fails int64) int64 {
	return min(int64(60)<<min(max(fails-1, 0), 6), 3600)
}

// errText is what a failed delivery says. Only texts made here (failed) are shown; anything
// else could carry the URL, which is a secret.
func errText(err error) string {
	var f failed
	if errors.As(err, &f) {
		return string(f)
	}
	return "delivery failed"
}
