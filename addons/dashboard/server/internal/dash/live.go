package dash

import (
	"bytes"
	"context"
	"encoding/json"
	"sync"
	"time"
)

// Live refresh (5 s while a page is visible). Per server, one `tando snapshot --json --follow -H
// <host>` runs while a visible page asks for that server: the server pushes a snapshot line every
// 5 s over one ssh session (tandod's live view; tando status --follow), and a poll is answered
// from the last line without running anything. Chosen over polling `snapshot --json` every 5 s
// with a 4 s cache because of the server's side: a poll is an ssh exec, a shell, sudo, the
// agent's bash and tando-status every 5 s (tens of ms of CPU each time, per page and server);
// a follow is one process that asks tandod's socket for a few rows every 5 s and collects the
// whole status once a minute (docs/MONITORING.md, "Live views"; measured in test/e2e-live.sh).
//
// An app's page still runs its own snapshot (releases, deploys, metrics, health) at most every
// CacheTTL, and gets the live app row and the server's numbers laid over it every poll.
// A server without a live view (an older tando there, no tandod, no cgroup v2: the follow exits
// at once without a line) is polled as before and asked again after LiveRetry.

const (
	liveFresh  = 12 * time.Second // a line this old still answers a poll (two missed frames)
	liveLinger = 30 * time.Second // a follow with no visible page asking ends after this
	liveRetry  = 10 * time.Minute // a server without a live view is asked again after this
	livePoll   = 5                // next_poll_s while a live line answers
)

type liveHost struct {
	data      json.RawMessage
	at        time.Time
	asked     time.Time
	running   bool
	noneUntil time.Time
	starts    int // follows started (tests)
}

type liveFeed struct {
	mu sync.Mutex
	m  map[string]*liveHost
	wg sync.WaitGroup // running follows (WaitStreams)
}

// liveFrame: the last line of host's follow when it is fresh. visible: a page on screen asks,
// which keeps (or starts) the follow.
func (s *Server) liveFrame(host string, visible bool) (json.RawMessage, time.Time, bool) {
	now := s.cfg.Now()
	l := &s.live
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.m == nil {
		l.m = map[string]*liveHost{}
	}
	h := l.m[host]
	if h == nil {
		h = &liveHost{}
		l.m[host] = h
	}
	if visible {
		h.asked = now
		if !h.running && now.After(h.noneUntil) {
			if sr, ok := s.cfg.Runner.(Streamer); ok {
				h.running = true
				h.starts++
				l.wg.Add(1)
				go s.follow(sr, host, h)
			}
		}
	}
	if h.data != nil && now.Sub(h.at) < liveFresh {
		return h.data, h.at, true
	}
	return nil, time.Time{}, false
}

// follow runs host's follow until no visible page asked for liveLinger or tando-dash stops.
func (s *Server) follow(sr Streamer, host string, h *liveHost) {
	defer s.live.wg.Done()
	ctx, cancel := context.WithCancel(s.base)
	defer cancel()
	go func() { // the linger: ended when no page asked for a while
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
			s.live.mu.Lock()
			idle := s.cfg.Now().Sub(h.asked) > liveLinger
			s.live.mu.Unlock()
			if idle {
				cancel()
				return
			}
		}
	}()
	lines := 0
	_, err := sr.Stream(ctx, Req{Argv: argvSnapshotFollow(host), Host: host, SlotWait: time.Second}, func(b []byte) {
		b = bytes.TrimSpace(b)
		if len(b) == 0 || !json.Valid(b) {
			return
		}
		d := append(json.RawMessage(nil), b...)
		s.live.mu.Lock()
		h.data, h.at = d, s.cfg.Now()
		s.live.mu.Unlock()
		lines++
	})
	s.live.mu.Lock()
	defer s.live.mu.Unlock()
	h.running = false
	if ctx.Err() == nil && lines == 0 { // it ended without a line: no live view there
		h.noneUntil = s.cfg.Now().Add(liveRetry)
		if err != nil {
			s.logf("live view of %s: %v", host, err)
		}
	}
}

// liveOver lays the live snapshot over an app's snapshot: the server's numbers, every app's row,
// the alerts, and the app's own status row.
func liveOver(appSnap, live json.RawMessage, app string) json.RawMessage {
	var a, l map[string]json.RawMessage
	if json.Unmarshal(appSnap, &a) != nil || json.Unmarshal(live, &l) != nil || a == nil {
		return appSnap
	}
	for k, v := range l {
		if k != "app" {
			a[k] = v
		}
	}
	var apps []map[string]json.RawMessage
	var obj map[string]json.RawMessage
	if json.Unmarshal(l["apps"], &apps) == nil && json.Unmarshal(a["app"], &obj) == nil && obj != nil {
		want, _ := json.Marshal(app)
		for _, row := range apps {
			if bytes.Equal(row["app"], want) {
				obj["status"], _ = json.Marshal(row)
				a["app"], _ = json.Marshal(obj)
				break
			}
		}
	}
	out, err := json.Marshal(a)
	if err != nil {
		return appSnap
	}
	return out
}
