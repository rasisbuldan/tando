package dash

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The allowlist: the only argv shapes tando-dash ever gives the tando CLI. Every run goes
// through Allowed (runner.go), whatever built the argv. A shape is a fixed verb, an exact list
// of positionals and a closed set of flags; any other token is refused. No shell is ever used:
// the argv is passed to execve as is.

type valueKind int

const (
	vNone    valueKind = iota // a boolean flag
	vHost                     // a host name, tando's rule (lib/common.sh valid_host), stricter
	vApp                      // an app name, tando's rule (lib/common.sh valid_app)
	vRange                    // 1h | 24h | 7d
	vCount                    // -n: 1 to 5000 lines
	vSince                    // --since: 15m, @epoch, 2026-11-13, "2026-11-13 14:30", 14:30 (lib/cmd-logx.sh lx_time)
	vLevel                    // --level: err, warning, notice, info, debug (and their aliases)
	vGrep                     // --grep: a fixed text, 1-256 characters, no control characters, no leading '-'
	vWorker                   // --worker: a-z first, then a-z 0-9 -
	vRelease                  // --release: a release id, YYYYMMDD-HHMMSS[-N]
	vEnvKey                   // env set KEY: tando's key rule (bin/tando cmd_env), at most 128
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
	// logs: a one-shot tail and a follow (-f), JSON lines; no --regex, --until, --deploy or pull
	{name: "logs", verb: []string{"logs"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"-H": {vHost, true}, "--json": {vNone, true}, "-n": {vCount, true},
			"--since": {vSince, false}, "--level": {vLevel, false}, "--grep": {vGrep, false},
			"--worker": {vWorker, false}, "--release": {vRelease, false}}},
	{name: "logs-follow", verb: []string{"logs"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"-H": {vHost, true}, "--json": {vNone, true}, "-f": {vNone, true},
			"-n": {vCount, true}, "--since": {vSince, false}, "--level": {vLevel, false}, "--worker": {vWorker, false}}},
	// the app pages' reads (M5): exact shapes; `env ls` only with --names (never a value)
	{name: "jobs", verb: []string{"jobs", "ls"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"--json": {vNone, true}, "-H": {vHost, true}}},
	{name: "requests", verb: []string{"requests", "summary"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"--json": {vNone, true}, "-H": {vHost, true}, "--since": {vRange, true}}},
	{name: "errors", verb: []string{"errors"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"--json": {vNone, true}, "-H": {vHost, true}}},
	{name: "envnames", verb: []string{"env", "ls"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"--names": {vNone, true}, "--json": {vNone, true}, "-H": {vHost, true}}},
	{name: "envlog", verb: []string{"env", "log"},
		flags: map[string]flagRule{"-a": {vApp, true}, "--json": {vNone, true}, "-H": {vHost, true}}},
	{name: "alerts", verb: []string{"alerts"}, flags: map[string]flagRule{"--json": {vNone, true}, "-H": {vHost, true}}},
	{name: "history", verb: []string{"history"}, flags: map[string]flagRule{"--json": {vNone, true}, "-H": {vHost, true}}},
	// writes (M4). Never --force or --yes: deploy runs in the app's recorded folder and stops
	// where the CLI would ask; env set takes the value on stdin, never in argv.
	{name: "deploy", verb: []string{"deploy"}, flags: map[string]flagRule{"-a": {vApp, true}, "-H": {vHost, true}}, write: true},
	{name: "rollback", verb: []string{"rollback"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"-H": {vHost, true}}, write: true},
	{name: "rollback-id", verb: []string{"rollback"}, pos: []valueKind{vApp, vRelease},
		flags: map[string]flagRule{"-H": {vHost, true}}, write: true},
	{name: "stop", verb: []string{"stop"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"-H": {vHost, true}}, write: true},
	{name: "start", verb: []string{"start"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"-H": {vHost, true}}, write: true},
	{name: "restart", verb: []string{"restart"}, pos: []valueKind{vApp},
		flags: map[string]flagRule{"-H": {vHost, true}}, write: true},
	{name: "env-set", verb: []string{"env", "set"}, pos: []valueKind{vEnvKey},
		flags: map[string]flagRule{"-a": {vApp, true}, "-H": {vHost, true}}, write: true},
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

var (
	sinceRe   = regexp.MustCompile(`^([0-9]{1,7}[smhdw]|@[0-9]{1,11}|now|[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?|[0-9]{2}:[0-9]{2}(:[0-9]{2})?)$`)
	workerRe  = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
	releaseRe = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}(-[0-9]{1,2})?$`)
	envKeyRe  = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)
	levels    = map[string]bool{"emerg": true, "alert": true, "crit": true, "fatal": true, "err": true, "error": true,
		"warning": true, "warn": true, "notice": true, "info": true, "debug": true}
)

// MaxLogLines: the most lines a tail asks for (-n)
const MaxLogLines = 5000

// ValidSince: the --since forms of tando logs (lib/cmd-logx.sh lx_time)
func ValidSince(s string) bool { return sinceRe.MatchString(s) }

// ValidLevel: the --level names tando logs knows
func ValidLevel(s string) bool { return levels[s] }

// ValidWorker: tando's worker names (--worker)
func ValidWorker(s string) bool { return workerRe.MatchString(s) }

// ValidRelease: a release id (lib/common.sh valid_id)
func ValidRelease(s string) bool { return releaseRe.MatchString(s) }

// ValidEnvKey: a key of env set (bin/tando: a letter or _, then letters, digits, _)
func ValidEnvKey(s string) bool { return envKeyRe.MatchString(s) }

// ValidGrep: the CLI's own rule (1-256 characters, no control characters, valid UTF-8), and no
// leading '-': tando's flag parser reads every token, so "--grep -f" would turn into a follow.
func ValidGrep(s string) bool {
	if s == "" || len(s) > 1024 || !utf8.ValidString(s) || utf8.RuneCountInString(s) > 256 || s[0] == '-' {
		return false
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f || r >= 0x80 && r < 0xa0 {
			return false
		}
	}
	return true
}

// ValidCount: -n of a tail
func ValidCount(s string) bool {
	n, err := strconv.Atoi(s)
	return err == nil && n >= 1 && n <= MaxLogLines && strconv.Itoa(n) == s
}

func validValue(k valueKind, v string) bool {
	switch k {
	case vCount:
		return ValidCount(v)
	case vSince:
		return ValidSince(v)
	case vLevel:
		return ValidLevel(v)
	case vGrep:
		return ValidGrep(v)
	case vWorker:
		return ValidWorker(v)
	case vRelease:
		return ValidRelease(v)
	case vHost:
		return ValidHost(v)
	case vApp:
		return ValidApp(v)
	case vRange:
		return ValidRange(v)
	case vEnvKey:
		return ValidEnvKey(v)
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

// logFilter: the filters of a tail or a follow, each checked by its Valid* rule
type logFilter struct {
	Since, Level, Grep, Worker, Release string
}

func argvLogs(host, app string, n int, f logFilter) []string {
	a := []string{"logs", app, "-H", host, "--json", "-n", strconv.Itoa(n)}
	return appendFilter(a, f)
}

func argvLogsFollow(host, app string, n int, f logFilter) []string {
	a := []string{"logs", app, "-H", host, "--json", "-f", "-n", strconv.Itoa(n)}
	return appendFilter(a, f)
}

func appendFilter(a []string, f logFilter) []string {
	for _, kv := range [][2]string{{"--since", f.Since}, {"--level", f.Level}, {"--grep", f.Grep}, {"--worker", f.Worker}, {"--release", f.Release}} {
		if kv[1] != "" {
			a = append(a, kv[0], kv[1])
		}
	}
	return a
}
