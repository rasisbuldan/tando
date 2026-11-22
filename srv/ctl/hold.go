package ctl

import (
	"context"
	"regexp"

	"tando/srv/internal/apps"
)

// Holding an app (docs/CONTROL-PLANE.md, "Hold"): app.hold takes it off line, as tando-agent's
// hold verb (stopped, disabled, Caddy's 503 page with the reason; no deploy, start, restart,
// rollback, restore, job or daily backup until app.release). The two reasons differ in who may
// lift them: a pause the app's own principal may set and release; a suspend (an abuse takedown,
// which also freezes evidence on the node) only tando-ctl-write may set or release. Which reason
// holds the app is read from its state file when the request runs (under the app's order in the
// request store), never taken from the request.

type identKey struct{}

// withIdent carries who sent the request to the verbs that decide by it (Serve sets it).
func withIdent(ctx context.Context, id Ident) context.Context {
	return context.WithValue(ctx, identKey{}, id)
}

// identOf is the request's sender; without one (a caller that did not set it), no rights.
func identOf(ctx context.Context) Ident {
	if id, ok := ctx.Value(identKey{}).(Ident); ok {
		return id
	}
	return Ident{}
}

// holdNoteRe: what a hold message may hold. It reaches the Caddyfile between double quotes
// (tando-agent checks it again): no brace (a placeholder: {env.*}, {file.*}), quote, backslash
// or control character.
var holdNoteRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 .,:;!?'()/@+_-]{0,199}$`)

// heldBy is the reason the app is held ("": not held), from its state file.
func (c *Ctl) heldBy(app string) string {
	st, _ := apps.State(c.Env.Root, app)
	switch st["hold"] {
	case "pause", "suspend":
		return st["hold"]
	case "":
		return ""
	}
	return "suspend" // (an unknown value is the stricter one)
}

func (c *Ctl) hold(ctx context.Context, r Request) (any, *Error) {
	var a struct {
		Reason  string `json:"reason"`
		Message string `json:"message"`
	}
	if e := decodeArgs(r, &a); e != nil {
		return nil, e
	}
	if a.Reason != "pause" && a.Reason != "suspend" {
		return nil, &Error{"bad_request", `args.reason: "pause" or "suspend"`}
	}
	if a.Message != "" && !holdNoteRe.MatchString(a.Message) {
		return nil, &Error{"bad_request", "args.message: at most 200 of letters, digits, space and . , : ; ! ? ' ( ) / @ + _ -"}
	}
	if e := c.exists(r.App); e != nil {
		return nil, e
	}
	id := identOf(ctx)
	if id.Mode != ModeWrite && (a.Reason == "suspend" || c.heldBy(r.App) == "suspend") {
		return nil, &Error{"forbidden", "a suspend is set and lifted by the principal tando-ctl-write only"}
	}
	args := []string{"hold", r.App, a.Reason}
	if a.Message != "" {
		args = append(args, a.Message)
	}
	return c.agent(ctx, "", args...)
}

func (c *Ctl) release(ctx context.Context, r Request) (any, *Error) {
	if e := decodeArgs(r, &struct{}{}); e != nil {
		return nil, e
	}
	if e := c.exists(r.App); e != nil {
		return nil, e
	}
	if identOf(ctx).Mode != ModeWrite && c.heldBy(r.App) == "suspend" {
		return nil, &Error{"forbidden", "a suspend is set and lifted by the principal tando-ctl-write only"}
	}
	return c.agent(ctx, "", "release", r.App)
}
