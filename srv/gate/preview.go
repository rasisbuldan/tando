package gate

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
	"tando/srv/internal/valid"
)

// Preview apps (docs/COMMANDS.md, "Preview apps"): <app>-<name>, a temporary copy of an app that
// tando-agent makes (preview-up) and destroys (preview-rm, or when it expires). A deploy key of
// the app may make and remove only these, and deploy to them: the preview gets a deploy user of
// its own (tando-d-<preview>) whose key list is a copy of the app's, so every rule of the gate
// (one app per uid, exact sudo rule, confined receiver, activation checks) applies to it as to any
// app. Revoking or rotating the app's key changes the copies too.

var (
	previewSlugRe = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	previewTTLRe  = regexp.MustCompile(`^[1-9][0-9]{0,3}[smhd]$`)
)

// ValidPreview: name is a preview name of app: "<app>-<slug>", a valid app name (24 characters at
// most), the slug lower case letters and digits in words separated by single dashes.
func ValidPreview(app, name string) bool {
	slug, ok := strings.CutPrefix(name, app+"-")
	// (24 characters at most, as tando-agent's valid_app: the app's group is tando-m-<name>)
	return ok && len(name) <= 24 && valid.App(app) && valid.App(name) && previewSlugRe.MatchString(slug)
}

// previewOf is the app a preview belongs to (app.conf's preview_of), "" for any other app.
func (g *Gate) previewOf(app string) string {
	p := kv(filepath.Join(g.appDir(app), "app.conf"), "preview_of")
	if valid.App(p) && ValidPreview(p, app) {
		return p
	}
	return ""
}

// mirrorKeys makes the preview's deploy user (made if need be) hold exactly the parent's keys.
func (g *Gate) mirrorKeys(parent, pv string) error {
	if g.previewOf(pv) != parent {
		return die("%s is not a preview of %s", pv, parent)
	}
	data, err := os.ReadFile(filepath.Join(g.home(parent), "keys"))
	if err != nil || countNonEmpty(data) == 0 {
		return nil // no deploy keys: nothing to mirror (the admin deploys it)
	}
	if err := g.ensureUser(pv); err != nil {
		return err
	}
	if err := atomicfile.Write(filepath.Join(g.home(pv), "keys"), data, atomicfile.Mode(0o600)); err != nil {
		return err
	}
	return g.writeKeys(pv)
}

// syncPreviews: the app's keys changed (added, revoked, rotated): its previews' deploy users get
// the same list; keys that went (ids) end their leases and every session of the preview users.
func (g *Gate) syncPreviews(parent string, ids []string) {
	ents, _ := os.ReadDir(g.P.CI)
	for _, e := range ents {
		pv := e.Name()
		if !ValidPreview(parent, pv) || g.previewOf(pv) != parent ||
			!fsinfo.RegularFollow(filepath.Join(g.appDir(pv), "app.conf")) {
			continue
		}
		data, err := os.ReadFile(filepath.Join(g.home(parent), "keys"))
		if err != nil {
			data = nil
		}
		if err := atomicfile.Write(filepath.Join(g.home(pv), "keys"), data, atomicfile.Mode(0o600)); err != nil {
			continue
		}
		g.writeKeys(pv)
		if len(ids) > 0 {
			g.endLeaseOf(pv, ids)
			g.evictUser(pv)
		}
	}
}

// rootPreview is root mode's preview-up / preview-rm of the deploy user of app (through its exact
// sudo rule; the name and ttl come on stdin like a lease token): the name is checked again here,
// then tando-agent (as root) makes or removes the preview, which it only does for a preview of
// this app. After preview-up the preview's deploy user holds this app's keys.
func (g *Gate) rootPreview(app, verb string) error {
	p, err := ReadParams(g.Stdin)
	if err != nil {
		return err
	}
	if !ValidPreview(app, p.Preview) || (verb == "preview-rm" && p.TTL != "") {
		return die("this key may make and remove previews named %s-<name> only", app)
	}
	pv := p.Preview
	call := []string{verb, app, pv}
	if p.TTL != "" {
		call = append(call, p.TTL)
	}
	o, err := g.agent(true, 10*60, call...)
	if err != nil {
		return Exit{1}
	}
	if verb == "preview-up" {
		if err := g.mirrorKeys(app, pv); err != nil {
			return err
		}
	}
	w := out.New(g.Stdout)
	for _, line := range bashread.LinesAll(o) {
		if k, v, ok := strings.Cut(line, "="); ok && previewKeys[k] {
			w.KV(k, v)
		}
	}
	return w.Flush()
}

// the lines of the agent's answer a key sees (never a server path or another app's name)
var previewKeys = map[string]bool{"preview": true, "parent": true, "created": true, "expires": true,
	"env_copied": true, "env_skipped": true, "link": true, "destroyed": true}
