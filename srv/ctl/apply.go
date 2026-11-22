package ctl

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"tando/srv/internal/apps"
	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
)

// apply: the app spec, declared whole, with a generation number. Steps, in order: the
// generation is checked (an older or the same generation as one applied is refused), env (set,
// then unset: env-set checks the app with the new env and puts the old one back when it breaks),
// then a deploy (the artifact with the spec's settings and domains, through app.deploy's path).
// A failed step stops the apply: the deploy step undoes itself (tando's activation goes back to
// the live release), an env step that was done stays (forward-only, documented); the generation
// is recorded only when every step is done, so the same generation can be sent again (with a
// new request id) and an older one stays refused.

// Spec is what the node keeps of the last apply: /var/lib/tando/ctl/spec/<app>.json (root 600).
// No env value is kept.
type Spec struct {
	Generation int64             `json:"generation"` // the last one applied in full
	Attempted  int64             `json:"attempted"`  // the highest one tried
	Failed     string            `json:"failed,omitempty"`
	Settings   map[string]string `json:"settings,omitempty"`
	Domains    []string          `json:"domains,omitempty"`
	Artifact   *DeployArgs       `json:"artifact,omitempty"`
	At         int64             `json:"at,omitempty"`
}

// ApplyArgs are apply's (and app.import's) args.
type ApplyArgs struct {
	Generation int64             `json:"generation"`
	Settings   map[string]string `json:"settings"`
	Domains    []string          `json:"domains"`
	Env        struct {
		Set   map[string]string `json:"set"`
		Unset []string          `json:"unset"`
	} `json:"env"`
	Artifact *DeployArgs `json:"artifact"`
}

// CheckGeneration: gen may be applied after s. Refused: not positive, older than one tried, or
// the one applied already (a retry of a failed one is allowed).
func CheckGeneration(s Spec, gen int64) *Error {
	switch {
	case gen < 1:
		return &Error{"bad_request", "args.generation: a number from 1"}
	case gen < s.Attempted:
		return &Error{"conflict", fmt.Sprintf("generation %d is older than generation %d, already sent (applied: %d)", gen, s.Attempted, s.Generation)}
	case gen == s.Generation:
		return &Error{"conflict", fmt.Sprintf("generation %d is applied already", gen)}
	}
	return nil
}

var domainRe = regexp.MustCompile(`^(?i)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$`)

func (a *ApplyArgs) check() *Error {
	for k, v := range a.Settings {
		if !specKeys[k] && !workerMemRe.MatchString(k) {
			return &Error{"bad_request", "args.settings: " + clean(k) + " is not a setting of the app spec (code settings come with the artifact)"}
		}
		if len(v) > 1000 || !printable(v) {
			return &Error{"bad_request", "args.settings: " + k + ": at most 1000 printable characters"}
		}
	}
	if len(a.Domains) > 50 {
		return &Error{"bad_request", "args.domains: at most 50"}
	}
	for _, d := range a.Domains {
		if len(d) > 253 || !domainRe.MatchString(d) {
			return &Error{"bad_request", "args.domains: not a domain name: " + clean(d)}
		}
	}
	for k, v := range a.Env.Set {
		if !envKeyRe.MatchString(k) {
			return &Error{"bad_request", "args.env.set: bad name " + clean(k)}
		}
		if !printable(v) {
			return &Error{"bad_request", "args.env.set: control characters in the value of " + k}
		}
	}
	for _, k := range a.Env.Unset {
		if !envKeyRe.MatchString(k) {
			return &Error{"bad_request", "args.env.unset: bad name " + clean(k)}
		}
		if _, ok := a.Env.Set[k]; ok {
			return &Error{"bad_request", "args.env: " + k + " is both set and unset"}
		}
	}
	if a.Artifact != nil {
		if e := a.Artifact.check(); e != nil {
			e.Message = strings.Replace(e.Message, "args.", "args.artifact.", 1)
			return e
		}
	}
	return nil
}

func (c *Ctl) specPath(app string) string { return filepath.Join(c.Dir, "spec", app+".json") }

// LoadSpec reads an app's spec (none: the zero Spec).
func (c *Ctl) LoadSpec(app string) (Spec, error) {
	var s Spec
	b, err := os.ReadFile(c.specPath(app))
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		return s, err
	}
	return s, json.Unmarshal(b, &s)
}

func (c *Ctl) saveSpec(app string, s Spec) error {
	if err := os.MkdirAll(filepath.Dir(c.specPath(app)), 0o700); err != nil {
		return err
	}
	b, _ := json.Marshal(s)
	return atomicfile.Write(c.specPath(app), b, atomicfile.Mode(0o600))
}

func (c *Ctl) apply(ctx context.Context, r Request) (any, *Error) { return c.applyRun(ctx, r, false) }
func (c *Ctl) appImport(ctx context.Context, r Request) (any, *Error) {
	return c.applyRun(ctx, r, true)
}

// applyRun runs apply; create: app.import (the app must not exist yet, and an artifact is needed).
func (c *Ctl) applyRun(ctx context.Context, r Request, create bool) (any, *Error) {
	var a ApplyArgs
	if e := decodeArgs(r, &a); e != nil {
		return nil, e
	}
	if e := a.check(); e != nil {
		return nil, e
	}
	exists := c.exists(r.App) == nil
	if create && exists {
		return nil, &Error{"conflict", r.App + " is on this node already: app.import makes a new app (apply changes one)"}
	}
	if !exists && c.draining() {
		return nil, &Error{"forbidden", "this node is draining: it takes no new app"}
	}
	s, err := c.LoadSpec(r.App)
	if err != nil {
		return nil, &Error{"internal", "the app's spec cannot be read: " + clean(err.Error())}
	}
	if !exists {
		s = Spec{} // (a spec left from a destroyed app of that name does not count)
	}
	if e := CheckGeneration(s, a.Generation); e != nil {
		return nil, e
	}
	art := a.Artifact
	if art == nil {
		art = s.Artifact
	}
	deploy := a.Artifact != nil || a.Settings != nil || a.Domains != nil || !exists
	if deploy && art == nil {
		return nil, &Error{"bad_request", "args.artifact: needed (settings take effect with a deploy, and no artifact was applied before)"}
	}
	s.Attempted, s.Failed = a.Generation, ""
	if err := c.saveSpec(r.App, s); err != nil {
		return nil, &Error{"internal", "the app's spec cannot be written: " + clean(err.Error())}
	}
	var done []string
	stepFail := func(step string, e *Error) (any, *Error) {
		s.Failed = step
		c.saveSpec(r.App, s)
		kept := "nothing was changed"
		if len(done) > 0 {
			kept = "done and kept: " + strings.Join(done, ", ")
		}
		return map[string]any{"failed_step": step, "steps_done": done}, &Error{e.Code, fmt.Sprintf("generation %d: step %s failed (%s): %s", a.Generation, step, kept, e.Message)}
	}
	res := map[string]any{"generation": a.Generation}
	if len(a.Env.Set) > 0 {
		keys := make([]string, 0, len(a.Env.Set))
		for k := range a.Env.Set {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		var b strings.Builder
		for _, k := range keys {
			b.WriteString(k + "=" + a.Env.Set[k] + "\n")
		}
		if _, e := c.agent(ctx, b.String(), "env-set", r.App); e != nil {
			return stepFail("env.set", e)
		}
		done = append(done, "env.set")
	}
	if len(a.Env.Unset) > 0 {
		if _, e := c.agent(ctx, strings.Join(a.Env.Unset, "\n")+"\n", "env-unset", r.App); e != nil {
			return stepFail("env.unset", e)
		}
		done = append(done, "env.unset")
	}
	if deploy {
		settings := a.Settings
		if settings == nil {
			settings = s.Settings
		}
		if settings == nil && exists {
			settings, _ = apps.Conf(c.Env.Root, r.App)
		}
		if settings == nil {
			settings = map[string]string{}
		}
		domains := a.Domains
		if domains == nil {
			domains = s.Domains
		}
		d, e := c.deployArtifact(ctx, r, *art, settings, domains)
		if e != nil {
			return stepFail("deploy", e)
		}
		done = append(done, "deploy")
		res["deploy"] = d
		s.Settings, s.Domains, s.Artifact = a.Settings, a.Domains, art
		if a.Settings == nil {
			s.Settings = settings
		}
		if a.Domains == nil {
			s.Domains = domains
		}
	}
	s.Generation, s.At = a.Generation, c.Env.Now().Unix()
	if err := c.saveSpec(r.App, s); err != nil {
		return nil, &Error{"internal", "the steps were done, but the generation could not be recorded: " + clean(err.Error())}
	}
	res["steps_done"] = done
	return res, nil
}

// export: the app's definition, portable: the spec, the code settings, domains, env names (the
// values only for the write principal that asks: never written anywhere on the node: a read
// verb, not kept by the request store), the artifact last applied, data pointers.
func (c *Ctl) export(_ context.Context, r Request) (any, *Error) {
	var a struct {
		Values bool `json:"values"`
	}
	if e := decodeArgs(r, &a); e != nil {
		return nil, e
	}
	if a.Values && r.ident.Mode != ModeWrite {
		return nil, &Error{"forbidden", "env values are exported only to the principal tando-ctl-write"}
	}
	if e := c.exists(r.App); e != nil {
		return nil, e
	}
	conf, _ := apps.Conf(c.Env.Root, r.App)
	st, _ := apps.State(c.Env.Root, r.App)
	s, _ := c.LoadSpec(r.App)
	spec, code := map[string]string{}, map[string]string{}
	for k, v := range conf {
		switch {
		case specKeys[k] || workerMemRe.MatchString(k):
			spec[k] = v
		case codeKeys[k] || workerKeyRe.MatchString(k) || jobKeyRe.MatchString(k):
			code[k] = v
		}
	}
	var doms []string
	for _, d := range strings.Fields(conf["domains"]) {
		doms = append(doms, strings.SplitN(d, "|", 2)[0])
	}
	env := readEnv(filepath.Join(apps.Dir(c.Env.Root, r.App), "env"))
	names := make([]string, 0, len(env))
	for k := range env {
		names = append(names, k)
	}
	sort.Strings(names)
	data := map[string]string{"database": conf["database"], "backup": conf["backup"]}
	if h := c.host(); conf["database"] == "postgres" && h["db_host"] != "" {
		data["data_node"] = h["db_host"]
	}
	out := map[string]any{"v": 1, "app": r.App, "generation": s.Generation, "settings": spec, "code_settings": code,
		"domains": doms, "env_names": names, "artifact": s.Artifact, "release": st["current"], "data": data}
	if a.Values {
		out["env"] = env
	}
	return out, nil
}

// readEnv reads an app's env file (NAME="value", backslash escapes) as the agent's env_load.
func readEnv(path string) map[string]string {
	b, _ := os.ReadFile(path)
	env := map[string]string{}
	for _, l := range bashread.LinesAll(b) {
		k, v, ok := strings.Cut(l, "=")
		if !ok || !envKeyRe.MatchString(k) {
			continue
		}
		v = strings.TrimPrefix(v, `"`)
		v = strings.TrimSuffix(v, `"`)
		var o strings.Builder
		for i := 0; i < len(v); i++ {
			if v[i] == '\\' && i+1 < len(v) {
				i++
			}
			o.WriteByte(v[i])
		}
		env[k] = o.String()
	}
	return env
}
