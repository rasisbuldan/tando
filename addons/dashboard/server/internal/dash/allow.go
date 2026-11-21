package dash

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// The allowlist: the only argv shapes tando-dash ever gives the tando CLI. Every run goes
// through Allowed (runner.go), whatever built the argv. A shape is a fixed verb, an exact list
// of positionals and a closed set of flags; any other token is refused. No shell is ever used:
// the argv is passed to execve as is.

type valueKind int

const (
	vNone  valueKind = iota // a boolean flag
	vHost                   // a host name, tando's rule (lib/common.sh valid_host), stricter
	vApp                    // an app name, tando's rule (lib/common.sh valid_app)
	vRange                  // 1h | 24h | 7d
)

type flagRule struct {
	kind     valueKind
	required bool
}

type shape struct {
	name  string
	verb  []string
	pos   []valueKind
	flags map[string]flagRule
	needs map[string]string // flag -> flag it needs (--range needs --app)
	write bool
}

// shapes: the table. Reads first, then writes (M4 adds deploy, rollback, stop, start, env set).
var shapes = []shape{
	{name: "version", verb: []string{"--version"}},
	{name: "help-snapshot", verb: []string{"help", "snapshot"}},
	{name: "snapshot", verb: []string{"snapshot"}, flags: map[string]flagRule{
		"--json": {vNone, true}, "-H": {vHost, true}, "--app": {vApp, false}, "--range": {vRange, false}},
		needs: map[string]string{"--range": "--app"}},
	{name: "doctor", verb: []string{"doctor"}, pos: []valueKind{vHost},
		flags: map[string]flagRule{"--json": {vNone, true}}},
	{name: "hoststatus", verb: []string{"host", "status"}, pos: []valueKind{vHost},
		flags: map[string]flagRule{"--json": {vNone, true}}},
	// exactly `health <app> --json -H <host>`: `health --forget` is a write hidden in a read verb
	{name: "health", verb: []string{"health"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"--json": {vNone, true}, "-H": {vHost, true}}},
	{name: "restart", verb: []string{"restart"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"-H": {vHost, true}}, write: true},
}

// ErrRefused: an argv that matches no shape of the table
var ErrRefused = errors.New("refused by tando-dash's allowlist")

var appRe = regexp.MustCompile(`^[a-z][a-z0-9-]{1,23}$`)

// ValidApp: tando's rule: a-z first, then a-z 0-9 -, 2 to 24 characters
func ValidApp(s string) bool { return appRe.MatchString(s) }

// ValidHost: tando's rule (letters, digits, . _ -) plus: 1-64 characters, no leading '-' or
// '.', no "..": a name is also a file name under ~/.config/tando/hosts and an argv token.
func ValidHost(s string) bool {
	if s == "" || len(s) > 64 || s[0] == '-' || s[0] == '.' || strings.Contains(s, "..") {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// ValidRange: the metric windows snapshot knows
func ValidRange(s string) bool { return s == "1h" || s == "24h" || s == "7d" }

func validValue(k valueKind, v string) bool {
	switch k {
	case vHost:
		return ValidHost(v)
	case vApp:
		return ValidApp(v)
	case vRange:
		return ValidRange(v)
	}
	return false
}

// Allowed: the shape argv matches (its name), or ErrRefused with the reason
func Allowed(argv []string) (*shape, error) {
	var why error = fmt.Errorf("%w: no such command", ErrRefused)
	for i := range shapes {
		sh := &shapes[i]
		if len(argv) < len(sh.verb) || !equal(argv[:len(sh.verb)], sh.verb) {
			continue
		}
		if err := sh.match(argv[len(sh.verb):]); err != nil {
			why = err
			continue
		}
		return sh, nil
	}
	return nil, why
}

func (sh *shape) match(rest []string) error {
	seen := map[string]bool{}
	npos := 0
	for i := 0; i < len(rest); i++ {
		t := rest[i]
		if strings.HasPrefix(t, "-") {
			r, ok := sh.flags[t]
			if !ok {
				return fmt.Errorf("%w: %s %s takes no %q", ErrRefused, sh.verb[0], strings.Join(sh.verb[1:], " "), t)
			}
			if seen[t] {
				return fmt.Errorf("%w: %s given twice", ErrRefused, t)
			}
			seen[t] = true
			if r.kind != vNone {
				if i+1 >= len(rest) || !validValue(r.kind, rest[i+1]) {
					return fmt.Errorf("%w: bad value for %s", ErrRefused, t)
				}
				i++
			}
			continue
		}
		if npos >= len(sh.pos) || !validValue(sh.pos[npos], t) {
			return fmt.Errorf("%w: unexpected argument %q", ErrRefused, t)
		}
		npos++
	}
	if npos != len(sh.pos) {
		return fmt.Errorf("%w: %d arguments, want %d", ErrRefused, npos, len(sh.pos))
	}
	for f, r := range sh.flags {
		if r.required && !seen[f] {
			return fmt.Errorf("%w: %s is required", ErrRefused, f)
		}
	}
	for f, need := range sh.needs {
		if seen[f] && !seen[need] {
			return fmt.Errorf("%w: %s needs %s", ErrRefused, f, need)
		}
	}
	return nil
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// argv builders: the reads of the API. Allowed checks them again at run time.

func argvSnapshot(host, app, rng string) []string {
	a := []string{"snapshot", "--json", "-H", host}
	if app != "" {
		a = append(a, "--app", app)
		if rng != "" {
			a = append(a, "--range", rng)
		}
	}
	return a
}

func argvDoctor(host string) []string     { return []string{"doctor", host, "--json"} }
func argvHostStatus(host string) []string { return []string{"host", "status", host, "--json"} }
