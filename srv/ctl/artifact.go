package ctl

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"tando/srv/internal/apps"
	"tando/srv/internal/valid"
)

// app.deploy: an immutable artifact (built elsewhere) fetched by the node, verified, unpacked and
// handed to the deploy path a laptop deploy reaches after its upload: configure (the settings),
// begin (the upload lease), the unpacked tree into incoming/ (agent artifact-put), activate (the
// activation unit: copy, pre-flight, backup, switch, verify, soak, rollback on failure). Nothing
// is built on the node.

// Manifest is tando-artifact.json.
type Manifest struct {
	V        int               `json:"v"`
	Settings map[string]string `json:"settings"`
	Source   string            `json:"source,omitempty"` // free text: a commit, a build id (recorded)
}

// codeKeys are the settings an artifact may carry: how its code starts, is checked and served.
// Resources, data, domains and schedules of the node are the app spec's (apply), never the
// artifact's.
var codeKeys = map[string]bool{
	"recipe": true, "start": true, "start_shell": true, "health": true, "health_expect": true,
	"health_timeout": true, "path": true, "spa": true, "compress": true, "data": true,
	"writable": true, "assets": true, "release": true, "release_shell": true,
	"release_timeout": true, "node_lite": true, "job_timeout": true, "job_spread": true,
	"job_missed": true,
}

// specKeys are the settings of the app spec (apply), kept across an artifact deploy.
var specKeys = map[string]bool{
	"memory": true, "cpu": true, "tasks": true, "io": true, "disk": true, "priority": true,
	"database": true, "backup": true, "idle_stop": true, "soak": true, "stop_timeout": true,
	"hold": true, "max_conns": true, "max_requests": true, "response_timeout": true,
	"body_max": true, "cold_timeout": true, "tmp_size": true, "log_max": true, "log_keep": true,
	"log_rate": true, "access_log": true, "request_log_max": true, "health_fails": true,
	"health_recover": true, "db_statement_timeout": true, "db_idle_tx_timeout": true,
	"db_temp_limit": true, "db_pool": true, "db_direct": true,
}

// artifactRecipes: an artifact is already built; recipes that build on the node (python's venv)
// or pull an image (container) are not deployed from one.
var artifactRecipes = map[string]bool{"node": true, "next": true, "static": true, "workerd": true}

var workerKeyRe = regexp.MustCompile(`^worker\.[a-z][a-z0-9-]{0,20}(\.stop_timeout)?$`)
var workerMemRe = regexp.MustCompile(`^worker\.([a-z][a-z0-9-]{0,20})\.memory$`)
var jobKeyRe = regexp.MustCompile(`^job\.[a-z][a-z0-9-]{0,20}(\.(timeout|spread|missed|cron))?$`)

// ParseManifest checks tando-artifact.json: v 1, only code settings, printable values.
func ParseManifest(b []byte) (Manifest, error) {
	var m Manifest
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&m); err != nil {
		return m, fmt.Errorf("tando-artifact.json: %s", clean(err.Error()))
	}
	if m.V != 1 {
		return m, fmt.Errorf("tando-artifact.json: v must be 1")
	}
	if len(m.Settings) > 200 || len(m.Source) > 200 || !printable(m.Source) {
		return m, fmt.Errorf("tando-artifact.json: too many settings, or a bad source")
	}
	for k, v := range m.Settings {
		if !codeKeys[k] && !workerKeyRe.MatchString(k) && !jobKeyRe.MatchString(k) {
			why := "not a setting an artifact may carry"
			if specKeys[k] || k == "domain" || k == "www" || workerMemRe.MatchString(k) {
				why = "a setting of the app spec (apply), not of the artifact"
			}
			return m, fmt.Errorf("tando-artifact.json: %s: %s", clean(k), why)
		}
		if len(v) > 1000 || !printable(v) {
			return m, fmt.Errorf("tando-artifact.json: %s: at most 1000 printable characters", k)
		}
	}
	r := m.Settings["recipe"]
	if r == "" {
		r = "node"
	}
	if !artifactRecipes[r] {
		return m, fmt.Errorf("tando-artifact.json: recipe %s is not deployed from an artifact (it builds or pulls on the node): node, next, static or workerd", clean(r))
	}
	return m, nil
}

func printable(s string) bool {
	return !strings.ContainsFunc(s, func(r rune) bool { return r < 0x20 || r == 0x7f })
}

// configureInput is what configure gets: the app spec's settings (spec: from the stored spec, or
// what app.conf has now) and the artifact's code settings, one key=value per line.
func configureInput(spec map[string]string, code map[string]string, domains []string) string {
	all := map[string]string{}
	for k, v := range spec {
		if specKeys[k] {
			all[k] = v
		}
		// a worker's memory only for a worker the code has
		if m := workerMemRe.FindStringSubmatch(k); m != nil {
			if _, ok := code["worker."+m[1]]; ok {
				all[k] = v
			}
		}
	}
	for k, v := range code {
		all[k] = v
	}
	keys := make([]string, 0, len(all))
	for k := range all {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k + "=" + all[k] + "\n")
	}
	if len(domains) > 0 {
		b.WriteString("domain=" + strings.Join(domains, " ") + "\n")
	}
	return b.String()
}

// DeployArgs are app.deploy's args.
type DeployArgs struct {
	URL    string `json:"url"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

func (a DeployArgs) check() *Error {
	if _, err := CheckURL(a.URL); err != nil {
		return &Error{"bad_request", "args.url: " + err.Error()}
	}
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(a.SHA256) {
		return &Error{"bad_request", "args.sha256: 64 lower-case hex digits"}
	}
	if a.Size <= 0 {
		return &Error{"bad_request", "args.size: the artifact's size in bytes"}
	}
	return nil
}

// ctlConf is /opt/tando/ctl (root's: the CA, the fetch allowlist and CA).
func (c *Ctl) ctlConf() string { return filepath.Join(c.Env.Root, "ctl") }

// ArtifactMaxMB is the default cap of one artifact (host.conf ctl_artifact_max_mb): the download,
// and a quarter of what it may unpack to (never more than app_max_mb).
const ArtifactMaxMB = 512

// ArtReserveMB: the free space the file system of the store keeps while an artifact is fetched
// and unpacked (and 5% of it, whichever is more).
const ArtReserveMB = 1024

// fetchPolicy: host.conf's limits, the operator's allowlist for this principal (fetch-allow for
// tando-ctl-write, the control plane's own artifact store; fetch-allow-apps for apps' principals,
// so a tenant never reaches what was opened for the control plane) and extra CA.
func (c *Ctl) fetchPolicy(id Ident) (FetchPolicy, Limits, *Error) {
	h := c.host()
	mb := int64(8192)
	if n, err := strconv.ParseInt(h["app_max_mb"], 10, 64); err == nil && n > 0 {
		mb = n
	}
	amb := int64(ArtifactMaxMB)
	if n, err := strconv.ParseInt(h["ctl_artifact_max_mb"], 10, 64); err == nil && n > 0 {
		amb = n
	}
	p := FetchPolicy{Timeout: 15 * time.Minute, MaxSize: min(amb, mb) << 20}
	// (fetch-allow-apps: what the operator opens to apps' own principals too; empty by default)
	allowFile := "fetch-allow-apps"
	if id.Mode == ModeWrite {
		allowFile = "fetch-allow"
	}
	allow, err := LoadAllow(filepath.Join(c.ctlConf(), allowFile))
	if err != nil {
		return p, Limits{}, &Error{"internal", clean(err.Error())}
	}
	p.Allow = allow
	pem, err := readRootFile(filepath.Join(c.ctlConf(), "fetch-ca.pem"), 1<<20)
	if err != nil {
		return p, Limits{}, &Error{"internal", clean(err.Error())}
	}
	if pem != nil {
		pool, perr := x509.SystemCertPool()
		if perr != nil || pool == nil {
			pool = x509.NewCertPool()
		}
		if !pool.AppendCertsFromPEM(pem) {
			return p, Limits{}, &Error{"internal", "/opt/tando/ctl/fetch-ca.pem has no certificate"}
		}
		p.Roots = pool
	}
	return p, Limits{MaxEntries: 200000, MaxBytes: min(4*amb, mb) << 20}, nil
}

// freeMB is the free space of the file system that holds dir, in MB, and its 5% (-1: unknown).
func freeMB(dir string) (free, pct5 int64) {
	var st syscall.Statfs_t
	if syscall.Statfs(dir, &st) != nil {
		return -1, 0
	}
	return int64(st.Bavail) * int64(st.Bsize) >> 20, int64(st.Blocks) * int64(st.Bsize) >> 20 / 20
}

// sweepArt removes what a crashed deploy left in art/ (older than the longest deploy).
func sweepArt(art string, now time.Time) {
	ents, _ := os.ReadDir(art)
	for _, e := range ents {
		if fi, err := e.Info(); err == nil && now.Sub(fi.ModTime()) > 3*time.Hour {
			os.RemoveAll(filepath.Join(art, e.Name()))
		}
	}
}

// stage fetches and unpacks the artifact into a fresh directory under the store (root 700); the
// caller removes it.
func (c *Ctl) stage(ctx context.Context, id Ident, tag string, a DeployArgs) (dir string, m Manifest, e *Error) {
	pol, lim, perr := c.fetchPolicy(id)
	if perr != nil {
		return "", m, perr
	}
	if a.Size > pol.MaxSize {
		return "", m, &Error{"failed", fmt.Sprintf("artifact: %d bytes is over this node's limit of %d MB (ctl_artifact_max_mb)", a.Size, pol.MaxSize>>20)}
	}
	art := filepath.Join(c.Dir, "art")
	if err := os.MkdirAll(art, 0o700); err != nil {
		return "", m, &Error{"internal", "cannot make " + art}
	}
	os.Chmod(art, 0o700)
	sweepArt(art, c.Env.Now())
	// room for the download and what it unpacks to, and the reserve kept besides
	free, pct := freeMB(art)
	reserve := max(int64(ArtReserveMB), pct)
	lim.MinFreeMB, lim.Dir = reserve, art
	if free >= 0 && free < (2*a.Size>>20)+reserve {
		return "", m, &Error{"failed", fmt.Sprintf("artifact: not enough free disk space on the node for it (%d MB free, %d MB kept free)", free, reserve)}
	}
	f, err := pol.Fetch(ctx, art, a.URL, a.Size, a.SHA256)
	if err != nil {
		msg := err.Error()
		if fe, ok := err.(*FetchError); ok && id.Mode != ModeWrite {
			msg = fe.Kind // (an app's principal learns nothing about what is behind the URL)
		}
		return "", m, &Error{"failed", "artifact: " + clean(msg)}
	}
	defer f.Close()
	dir, err = os.MkdirTemp(art, tag+"-")
	if err != nil {
		return "", m, &Error{"internal", "cannot make a staging directory"}
	}
	u, err := UnpackFile(ctx, c.Env.Run, f, filepath.Join(dir, "t"), lim)
	if err != nil {
		os.RemoveAll(dir)
		return "", m, &Error{"failed", "artifact: " + clean(err.Error())}
	}
	if m, err = ParseManifest(u.Manifest); err != nil {
		os.RemoveAll(dir)
		return "", m, &Error{"failed", "artifact: " + clean(err.Error())}
	}
	return dir, m, nil
}

var tagRe = regexp.MustCompile(`[^A-Za-z0-9_-]`)

// appDeploy: app.deploy. The write principal may create the app (not on a draining node); an
// app's principal deploys its own app.
func (c *Ctl) appDeploy(ctx context.Context, r Request) (any, *Error) {
	var a DeployArgs
	if e := decodeArgs(r, &a); e != nil {
		return nil, e
	}
	if e := a.check(); e != nil {
		return nil, e
	}
	exists := c.exists(r.App) == nil
	if !exists {
		if r.ident.Mode == ModeApp {
			return nil, &Error{"not_found", "no app " + r.App + " on this node"}
		}
		if c.draining() {
			return nil, &Error{"forbidden", "this node is draining: it takes no new app"}
		}
	}
	return c.deployArtifact(ctx, r, a, nil, nil)
}

// deployArtifact runs one artifact deploy: spec (nil: the app's current spec settings) and
// domains (apply's) go with the artifact's code settings.
func (c *Ctl) deployArtifact(ctx context.Context, r Request, a DeployArgs, spec map[string]string, domains []string) (map[string]string, *Error) {
	if spec == nil {
		spec, _ = apps.Conf(c.Env.Root, r.App)
	}
	// before anything is fetched: an existing app that is held, busy past its wait, or over the
	// node's memory admission with this spec is refused by configure's own check
	if c.exists(r.App) == nil && valid.App(r.App) {
		if _, e := c.agent(ctx, configureInput(spec, nil, domains)+"check=1\n", "configure", r.App); e != nil {
			return nil, e
		}
	}
	dir, m, e := c.stage(ctx, r.ident, tagRe.ReplaceAllString(r.App+"-"+r.RequestID, "_"), a)
	if e != nil {
		return nil, e
	}
	defer os.RemoveAll(dir)
	res, e := c.deployTree(ctx, r.App, filepath.Join(dir, "t", "release"), configureInput(spec, m.Settings, domains))
	if res != nil {
		res["sha256"] = a.SHA256
		if m.Source != "" {
			res["source"] = clean(m.Source)
		}
	}
	return res, e
}

// deployTree is the laptop deploy's path from its upload on: configure, begin, the tree into
// incoming/, activate, and the activation followed to its result.
func (c *Ctl) deployTree(ctx context.Context, app, tree, settings string) (map[string]string, *Error) {
	if !valid.App(app) {
		return nil, &Error{"bad_request", "bad app name"}
	}
	cfg, e := c.agent(ctx, settings, "configure", app)
	if e != nil {
		return nil, e
	}
	conf := cfg["conf"]
	b, e := c.agent(ctx, "", "begin", app, c.Caller)
	if e != nil {
		return nil, e
	}
	tok := b["token"]
	if tok == "" {
		return nil, &Error{"internal", "begin gave no upload token"}
	}
	if _, e := c.agent(ctx, tok+"\n"+tree+"\n", "artifact-put", app); e != nil {
		c.agent(context.WithoutCancel(ctx), tok+"\n", "end", app)
		return nil, e
	}
	act, e := c.agent(ctx, tok+"\n"+conf+"\n", "activate", app, "0", "0")
	if e != nil {
		c.agent(context.WithoutCancel(ctx), tok+"\n", "end", app)
		return nil, e
	}
	id := act["id"]
	res := map[string]string{"release": id, "created": cfg["created"]}
	if act["same"] == "1" {
		res["result"], res["same"] = "verified", "1"
		return res, nil
	}
	return c.follow(ctx, app, id, res)
}

// follow polls deploy-status until the activation's result.
func (c *Ctl) follow(ctx context.Context, app, id string, res map[string]string) (map[string]string, *Error) {
	if !valid.App(app) || !valid.ID(id) {
		return res, &Error{"internal", "activate gave no release id"}
	}
	for {
		st, e := c.agent(ctx, "", "deploy-status", app, id)
		if e != nil {
			return res, e
		}
		switch st["result"] {
		case "ok", "verified":
			res["result"] = "verified"
			return res, nil
		case "failed", "rolledback", "bad", "superseded", "unknown":
			res["result"] = st["result"]
			return res, &Error{"failed", "release " + id + ": " + or(st["message"], st["result"])}
		}
		select {
		case <-ctx.Done():
			return res, &Error{"pending", "release " + id + " is still being activated: app.status and app.releases show its end"}
		case <-time.After(2 * time.Second):
		}
	}
}

// draining: node.drain set it (no new apps).
func (c *Ctl) draining() bool {
	_, err := os.Stat(filepath.Join(c.Dir, "draining"))
	return err == nil
}
