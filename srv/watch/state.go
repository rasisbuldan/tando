package watch

import (
	"maps"
	"regexp"
	"slices"
	"strings"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/kvfile"
)

// store is a key=value file held in memory that remembers whether it changed, so that a run in
// which nothing changed writes nothing (the shell's ws/wu/vs with DIRTY and VDIRTY).
//
// Two of them: the durable state /var/lib/tando/watch/state (alert states, firing times,
// notifier backoff; written atomically, 600) and the volatile state /run/tando-watch/vstate
// (counters that may be lost at a reboot: last run, probe windows, deploy grace; tmpfs, 600).
type store struct {
	m     map[string]string
	dirty bool
}

func newStore(m map[string]string) *store {
	if m == nil {
		m = map[string]string{}
	}
	return &store{m: m}
}

func (s *store) get(k string) string            { return s.m[k] }
func (s *store) has(k string) bool              { _, ok := s.m[k]; return ok }
func (s *store) lookup(k string) (string, bool) { v, ok := s.m[k]; return v, ok }

// or is the value of k, or def when it is empty or missing (bash ${W[k]:-def}).
func (s *store) or(k, def string) string {
	if v := s.m[k]; v != "" {
		return v
	}
	return def
}

// n is the value of k as a number, def when empty, missing or not a number.
func (s *store) n(k string, def int64) int64 {
	v := s.m[k]
	if v == "" {
		return def
	}
	return num(v, def)
}

func (s *store) set(k, v string) {
	if old, ok := s.m[k]; ok && old == v {
		return
	}
	s.m[k] = v
	s.dirty = true
}

func (s *store) del(keys ...string) {
	for _, k := range keys {
		if _, ok := s.m[k]; ok {
			delete(s.m, k)
			s.dirty = true
		}
	}
}

// keys in byte order (bash iterated its hash order; nothing depends on the order).
func (s *store) keys() []string { return slices.Sorted(maps.Keys(s.m)) }

func (s *store) save(path string) error {
	if _, err := kvfile.Save(path, s.m, atomicfile.Mode(0o600)); err != nil {
		return err
	}
	s.dirty = false
	return nil
}

// loadQuiet reads a key=value file; a missing or unreadable one is empty (the shell's
// `[[ -r $f ]] || return 0`: doctor and brief run without root and see no state).
func loadQuiet(path string) map[string]string {
	m, err := kvfile.Load(path)
	if err != nil {
		return map[string]string{}
	}
	return m
}

var (
	stRe   = regexp.MustCompile(`^(ok|pending|firing)$`)
	oomcRe = regexp.MustCompile(`^[0-9]+:[0-9]+(:[0-9]+)?$`)
	numsRe = regexp.MustCompile(`^[0-9]+(,[0-9]+)*$`)
)

// loadState reads the durable state with every value checked: states are words, details and
// errors text, the OOM counters a triple, everything else numbers or lists of numbers. Anything
// else is dropped (and the file is rewritten without it).
func loadState(path string) *store {
	s := newStore(loadQuiet(path))
	for k, v := range s.m {
		var ok bool
		switch {
		case strings.HasSuffix(k, ".st"):
			ok = stRe.MatchString(v)
		case strings.HasSuffix(k, ".det"), k == "_host.oom_d", len(k) >= 8 && strings.HasPrefix(k, "_nf.") && strings.HasSuffix(k, ".err"):
			ok = true
		case k == "_oomc":
			ok = oomcRe.MatchString(v)
		case strings.HasSuffix(k, ".ns"):
			ok = v == "firing"
		default:
			ok = numsRe.MatchString(v)
		}
		if !ok {
			delete(s.m, k)
			s.dirty = true
		}
	}
	return s
}
