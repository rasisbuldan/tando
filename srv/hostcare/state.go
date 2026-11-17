package hostcare

import (
	"sort"
	"strconv"
	"strings"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/decimal"
	"tando/srv/internal/kvfile"
)

// State is what runs remember (/var/lib/tando/hostcare/state, root 600, key=value):
//
//	since.<finding>=<epoch>     when the finding stopped being ok
//	alert.<check>=<epoch>       when the alert check turned bad
//	sec.<package>=<epoch>       when a security update of the package was first seen pending
//	ev.<kind>.<hour>=<count>    kernel I/O errors, OOM kills, failed ssh logins per hour (24 h)
//	ev.ioerr.last=<text>        the last I/O error line (cleaned, 200 characters)
//	jcursor=<cursor>            where the journal was read up to
//	lock.since=<epoch>          since when dpkg's lock is held (lock.pid)
//	clock.unsync=<epoch>        since when the clock is not synchronised
//	hist.seen=<epoch>           the last apt run of the history that was written to the audit log
//	reboot.ok=<epoch>           the last reboot by tando that came back healthy
//	planned=<epoch>             the owner planned a reboot for the next window (tando host reboot)
type State struct {
	m     map[string]string
	dirty bool
}

func loadState(p string) *State {
	m, err := kvfile.Load(p)
	if err != nil || m == nil {
		m = map[string]string{}
	}
	return &State{m: m}
}

func (s *State) save(p string) error {
	if !s.dirty {
		return nil
	}
	_, err := kvfile.Save(p, s.m, atomicfile.Mode(0o600))
	if err == nil {
		s.dirty = false
	}
	return err
}

func (s *State) get(k string) string { return s.m[k] }
func (s *State) num(k string) int64 {
	n, _ := decimal.Parse(s.m[k], 18)
	return n
}
func (s *State) set(k, v string) {
	v = strings.ReplaceAll(v, "\n", " ")
	if s.m[k] != v {
		s.m[k], s.dirty = v, true
	}
}
func (s *State) setNum(k string, n int64) { s.set(k, strconv.FormatInt(n, 10)) }
func (s *State) del(k string) {
	if _, ok := s.m[k]; ok {
		delete(s.m, k)
		s.dirty = true
	}
}

// since returns when key turned bad: now the first time bad is seen, kept while it stays bad,
// dropped when it is good again.
func (s *State) since(key string, bad bool, now int64) int64 {
	if !bad {
		s.del(key)
		return 0
	}
	if t := s.num(key); t > 0 {
		return t
	}
	s.setNum(key, now)
	return now
}

// keys with a prefix, sorted.
func (s *State) keys(prefix string) []string {
	var res []string
	for k := range s.m {
		if strings.HasPrefix(k, prefix) {
			res = append(res, k)
		}
	}
	sort.Strings(res)
	return res
}

// addEvent counts an event in its hour.
func (s *State) addEvent(kind string, at int64) {
	k := "ev." + kind + "." + strconv.FormatInt(at/3600*3600, 10)
	s.setNum(k, s.num(k)+1)
}

// events counts kind over the 24 hours before now, and drops older counts.
func (s *State) events(kind string, now int64) int {
	n := 0
	for _, k := range s.keys("ev." + kind + ".") {
		h, ok := decimal.Parse(strings.TrimPrefix(k, "ev."+kind+"."), 12)
		if !ok {
			continue
		}
		if h+3600 <= now-86400 {
			s.del(k)
			continue
		}
		n += int(s.num(k))
	}
	return n
}
