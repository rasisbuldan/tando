package ctl

import (
	"bytes"
	"context"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/apps"
	"tando/srv/internal/bashread"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
	"tando/srv/internal/usage"
	"tando/srv/internal/valid"
)

type appArg int

const (
	appNone     appArg = iota // a node verb
	appRequired               // an app's verb
	appOptional               // a node verb an app can be narrowed to (alerts, usage)
)

type verb struct {
	write     bool // changes something: needs a request_id, goes through the store
	writeOnly bool // only tando-ctl-write (not an app's principal)
	nodeOnly  bool // never for an app's principal
	app       appArg
	timeout   time.Duration
	run       func(c *Ctl, ctx context.Context, r Request) (any, *Error)
}

var verbs map[string]verb

func init() {
	verbs = map[string]verb{
		"inventory":     {app: appNone, nodeOnly: true, timeout: time.Minute, run: (*Ctl).inventory},
		"alerts":        {app: appOptional, timeout: time.Minute, run: (*Ctl).alerts},
		"usage":         {app: appOptional, timeout: time.Minute, run: (*Ctl).usage},
		"app.status":    {app: appRequired, timeout: time.Minute, run: (*Ctl).appStatus},
		"app.releases":  {app: appRequired, timeout: time.Minute, run: (*Ctl).releases},
		"app.history":   {app: appRequired, timeout: time.Minute, run: (*Ctl).history},
		"app.restart":   {write: true, app: appRequired, timeout: 10 * time.Minute, run: svc("restart")},
		"app.stop":      {write: true, app: appRequired, timeout: 10 * time.Minute, run: svc("stop")},
		"app.start":     {write: true, app: appRequired, timeout: 10 * time.Minute, run: svc("start")},
		"app.rollback":  {write: true, app: appRequired, timeout: 30 * time.Minute, run: (*Ctl).rollback},
		"app.env.set":   {write: true, app: appRequired, timeout: 10 * time.Minute, run: (*Ctl).envSet},
		"app.env.unset": {write: true, app: appRequired, timeout: 10 * time.Minute, run: (*Ctl).envUnset},
		"app.destroy":   {write: true, writeOnly: true, app: appRequired, timeout: 30 * time.Minute, run: (*Ctl).destroy},
		"app.deploy":    {write: true, app: appRequired, timeout: 75 * time.Minute, run: (*Ctl).appDeploy},
	}
}

func verbNames() []string {
	n := make([]string, 0, len(verbs))
	for k := range verbs {
		n = append(n, k)
	}
	sort.Strings(n)
	return n
}

// exists: the app is on this node.
func (c *Ctl) exists(app string) *Error {
	names, _ := apps.Names(c.Env.Root)
	for _, a := range names {
		if a == app {
			return nil
		}
	}
	return &Error{"not_found", "no app " + app + " on this node"}
}

var kvKeyRe = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)

// agent runs a tando-agent verb as root and returns its key=value lines; a failure is "failed"
// with the agent's own reason (its "tando-agent: ..." lines).
func (c *Ctl) agent(ctx context.Context, stdin string, args ...string) (map[string]string, *Error) {
	var stderr bytes.Buffer
	cmd := run.Cmd{Argv: append([]string{agentPath}, args...), Stderr: &stderr,
		Env: []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C", "SUDO_USER=" + c.Caller}}
	if dl, ok := ctx.Deadline(); ok {
		cmd.Timeout = time.Until(dl)
	}
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	o, err := c.Env.Run.Output(ctx, cmd)
	res := map[string]string{}
	for _, l := range bashread.LinesAll(o) {
		k, v, ok := strings.Cut(l, "=")
		if ok && kvKeyRe.MatchString(k) {
			res[k] = out.Clean(v)
		}
	}
	if err != nil {
		return res, &Error{"failed", agentWhy(stderr.Bytes(), err)}
	}
	return res, nil
}

// agentWhy is the agent's reason: its "tando-agent: " lines (cleaned, at most 1000 bytes).
func agentWhy(stderr []byte, err error) string {
	var why []string
	for _, l := range bashread.LinesAll(stderr) {
		if m, ok := strings.CutPrefix(l, "tando-agent: "); ok {
			why = append(why, out.Clean(m))
		}
	}
	s := strings.Join(why, "; ")
	if s == "" {
		s = "tando-agent failed: " + out.Clean(err.Error())
	}
	if len(s) > 1000 {
		s = s[:1000]
	}
	return s
}

func svc(v string) func(c *Ctl, ctx context.Context, r Request) (any, *Error) {
	return func(c *Ctl, ctx context.Context, r Request) (any, *Error) {
		if e := decodeArgs(r, &struct{}{}); e != nil {
			return nil, e
		}
		if e := c.exists(r.App); e != nil {
			return nil, e
		}
		return c.agent(ctx, "", v, r.App)
	}
}

func (c *Ctl) rollback(ctx context.Context, r Request) (any, *Error) {
	var a struct {
		To string `json:"to"`
	}
	if e := decodeArgs(r, &a); e != nil {
		return nil, e
	}
	if e := c.exists(r.App); e != nil {
		return nil, e
	}
	args := []string{"rollback", r.App}
	if a.To != "" {
		if !valid.ID(a.To) {
			return nil, &Error{"bad_request", "args.to: not a release id"}
		}
		args = append(args, a.To)
	}
	return c.agent(ctx, "", args...)
}

var envKeyRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)

func (c *Ctl) envSet(ctx context.Context, r Request) (any, *Error) {
	var a struct {
		Vars map[string]string `json:"vars"`
	}
	if e := decodeArgs(r, &a); e != nil {
		return nil, e
	}
	if len(a.Vars) == 0 {
		return nil, &Error{"bad_request", "args.vars: at least one NAME: value"}
	}
	keys := make([]string, 0, len(a.Vars))
	for k, v := range a.Vars {
		if !envKeyRe.MatchString(k) {
			return nil, &Error{"bad_request", "args.vars: bad name " + clean(k)}
		}
		if strings.ContainsFunc(v, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
			return nil, &Error{"bad_request", "args.vars: control characters in the value of " + k}
		}
		keys = append(keys, k)
	}
	if e := c.exists(r.App); e != nil {
		return nil, e
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k + "=" + a.Vars[k] + "\n")
	}
	return c.agent(ctx, b.String(), "env-set", r.App)
}

func (c *Ctl) envUnset(ctx context.Context, r Request) (any, *Error) {
	var a struct {
		Names []string `json:"names"`
	}
	if e := decodeArgs(r, &a); e != nil {
		return nil, e
	}
	if len(a.Names) == 0 {
		return nil, &Error{"bad_request", "args.names: at least one name"}
	}
	for _, k := range a.Names {
		if !envKeyRe.MatchString(k) {
			return nil, &Error{"bad_request", "args.names: bad name " + clean(k)}
		}
	}
	if e := c.exists(r.App); e != nil {
		return nil, e
	}
	return c.agent(ctx, strings.Join(a.Names, "\n")+"\n", "env-unset", r.App)
}

// destroy needs args.confirm = the app's name (a typo in app must not destroy another app);
// purge also drops the final backup of its data (as tando destroy --purge).
func (c *Ctl) destroy(ctx context.Context, r Request) (any, *Error) {
	var a struct {
		Confirm string `json:"confirm"`
		Purge   bool   `json:"purge"`
	}
	if e := decodeArgs(r, &a); e != nil {
		return nil, e
	}
	if a.Confirm != r.App {
		return nil, &Error{"bad_request", "app.destroy needs args.confirm set to the app's name"}
	}
	if e := c.exists(r.App); e != nil {
		return nil, e
	}
	args := []string{"destroy", r.App}
	if a.Purge {
		args = append(args, "purge")
	}
	return c.agent(ctx, "", args...)
}

// releases: the app's releases, newest first (the agent's rel rows).
func (c *Ctl) releases(ctx context.Context, r Request) (any, *Error) {
	if e := decodeArgs(r, &struct{}{}); e != nil {
		return nil, e
	}
	if e := c.exists(r.App); e != nil {
		return nil, e
	}
	var stderr bytes.Buffer
	o, err := c.Env.Run.Output(ctx, run.Cmd{Argv: []string{agentPath, "releases", r.App}, Stderr: &stderr, Timeout: time.Minute})
	if err != nil {
		return nil, &Error{"failed", agentWhy(stderr.Bytes(), err)}
	}
	type rel struct {
		ID       string `json:"id"`
		Status   string `json:"status"`
		Current  bool   `json:"current"`
		LastGood bool   `json:"last_good"`
	}
	rs := []rel{}
	for _, l := range bashread.LinesAll(o) {
		f := strings.Split(l, "\t")
		if len(f) >= 5 && f[0] == "rel" && valid.ID(f[1]) {
			rs = append(rs, rel{ID: f[1], Status: out.Clean(f[2]), Current: f[3] == "1", LastGood: f[4] == "1"})
		}
	}
	return map[string]any{"releases": rs}, nil
}

// history: the app's last n operations (history.tsv: deploys, rollbacks, restarts).
func (c *Ctl) history(_ context.Context, r Request) (any, *Error) {
	a := struct {
		N int `json:"n"`
	}{N: 20}
	if e := decodeArgs(r, &a); e != nil {
		return nil, e
	}
	if a.N < 1 || a.N > 1000 {
		return nil, &Error{"bad_request", "args.n: 1 to 1000"}
	}
	if e := c.exists(r.App); e != nil {
		return nil, e
	}
	type op struct {
		Time    int64   `json:"time"`
		ID      string  `json:"id"`
		Kind    string  `json:"kind"`
		Result  string  `json:"result"`
		Seconds float64 `json:"seconds"`
		Note    string  `json:"note"`
	}
	data, _ := readTail(apps.Dir(c.Env.Root, r.App)+"/history.tsv", 1<<20)
	var ops []op
	for _, l := range bashread.LinesAll(data) {
		f := strings.Split(l, "\t")
		if len(f) != 12 && len(f) != 13 {
			continue
		}
		t, err := strconv.ParseInt(f[0], 10, 64)
		if err != nil {
			continue
		}
		s, _ := strconv.ParseFloat(f[4], 64)
		ops = append(ops, op{Time: t, ID: out.Clean(f[1]), Kind: out.Clean(f[2]), Result: out.Clean(f[3]), Seconds: s, Note: out.Clean(dash(f[11]))})
	}
	if len(ops) > a.N {
		ops = ops[len(ops)-a.N:]
	}
	if ops == nil {
		ops = []op{}
	}
	return map[string]any{"history": ops}, nil
}

func dash(s string) string {
	if s == "-" {
		return ""
	}
	return s
}

// usage: the metering ledger from a cursor (internal/usage).
func (c *Ctl) usage(_ context.Context, r Request) (any, *Error) {
	a := struct {
		Since int64 `json:"since"`
		Limit int   `json:"limit"`
	}{Limit: 5000}
	if e := decodeArgs(r, &a); e != nil {
		return nil, e
	}
	if a.Since < 0 || a.Limit < 1 || a.Limit > 50000 {
		return nil, &Error{"bad_request", "args: since >= 0, limit 1 to 50000"}
	}
	p, err := usage.Read(c.Usage, a.Since, a.Limit, r.App)
	if err != nil {
		return nil, &Error{"internal", "the ledger cannot be read: " + clean(err.Error())}
	}
	return p, nil
}
