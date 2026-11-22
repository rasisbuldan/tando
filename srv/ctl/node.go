package ctl

import (
	"context"
	"os"
	"path/filepath"
	"strconv"

	"tando/srv/internal/apps"
	"tando/srv/internal/atomicfile"
	"tando/srv/internal/valid"
)

// node.drain: the node takes no new app (app.deploy, apply and app.import of an app that is not
// here are refused, and so is a laptop CLI's first deploy: tando-agent configure reads the same
// flag); the inventory says draining. With stop_apps, the apps are stopped in the order given
// (stop_order; the others after them, by name), one at a time; the first failure stops there.
// off: true ends draining (stopped apps stay stopped: app.start each).
func (c *Ctl) drain(ctx context.Context, r Request) (any, *Error) {
	var a struct {
		Off       bool     `json:"off"`
		StopApps  bool     `json:"stop_apps"`
		StopOrder []string `json:"stop_order"`
	}
	if e := decodeArgs(r, &a); e != nil {
		return nil, e
	}
	if a.Off && (a.StopApps || len(a.StopOrder) > 0) {
		return nil, &Error{"bad_request", "args: off with stop_apps or stop_order"}
	}
	for _, n := range a.StopOrder {
		if !valid.App(n) {
			return nil, &Error{"bad_request", "args.stop_order: bad app name " + clean(n)}
		}
	}
	f := filepath.Join(c.Dir, "draining")
	if a.Off {
		if err := os.Remove(f); err != nil && !os.IsNotExist(err) {
			return nil, &Error{"internal", clean(err.Error())}
		}
		return map[string]any{"draining": false}, nil
	}
	if err := os.MkdirAll(c.Dir, 0o700); err != nil {
		return nil, &Error{"internal", clean(err.Error())}
	}
	if _, err := os.Stat(f); err != nil {
		if err := atomicfile.Write(f, []byte(strconv.FormatInt(c.Env.Now().Unix(), 10)+"\n"), atomicfile.Mode(0o644)); err != nil {
			return nil, &Error{"internal", clean(err.Error())}
		}
	}
	res := map[string]any{"draining": true}
	if !a.StopApps {
		return res, nil
	}
	names, _ := apps.Names(c.Env.Root)
	here := map[string]bool{}
	for _, n := range names {
		here[n] = true
	}
	var order []string
	seen := map[string]bool{}
	for _, n := range append(append([]string{}, a.StopOrder...), names...) {
		if here[n] && !seen[n] {
			order, seen[n] = append(order, n), true
		}
	}
	stopped := []string{}
	for _, n := range order {
		if st, _ := apps.State(c.Env.Root, n); st["current"] == "" {
			continue // (nothing deployed: nothing runs)
		}
		if _, e := c.agent(ctx, "", "stop", n); e != nil {
			res["stopped"] = stopped
			return res, &Error{"failed", "stopping " + n + " failed (stopped before it: " + strconv.Itoa(len(stopped)) + "): " + e.Message}
		}
		stopped = append(stopped, n)
	}
	res["stopped"] = stopped
	return res, nil
}
