package status

import (
	"bytes"
	"context"
	"os"
	"strings"
	"testing"

	"tando/srv/internal/out/outtest"
)

// Every row tando-status makes goes through an out.Writer (the sink of each verb): control, C1
// and bidi bytes in app.conf, the state, the activation file (its keys too), activation.log and
// the history come out clean (srv/README.md, Output).
func TestOutputClean(t *testing.T) {
	h := newHost(t)
	h.euid = 0
	x := outtest.Hostile
	id := "20261114-170102"
	h.app("web", "port=4100\nrecipe="+x+"\ndomains=a.example.com|"+x+"|off "+x+"\nuser="+x+"\n",
		"current="+id+"\nstatus_"+id+"="+x+"\nphase="+x+"\ntarget="+x+"\nlast_backup="+x+"\n")
	os.MkdirAll(h.path("root/apps/web/releases/"+id), 0o755)
	h.write("root/apps/web/history.tsv", strings.Repeat(x+"\t", 11)+x+"\n"+id+"\t\t\t\t\t\t\t\t\t\t\t"+x+"\n")
	h.write("root/apps/web/activation", "id="+id+"\nresult=failed\nphase="+x+"\n"+x+"="+x+"\nmessage="+x+"\n")
	h.write("root/apps/web/activation.log", "line "+x+"\n")
	h.write("root/host.conf", "apps_domain="+x+"\ntls="+x+"\npodman="+x+"\n")
	ctx := context.Background()
	for name, verb := range map[string]func(c *Collector, b *bytes.Buffer) error{
		"status":        func(c *Collector, b *bytes.Buffer) error { return c.Status(ctx, b, "") },
		"status web":    func(c *Collector, b *bytes.Buffer) error { return c.Status(ctx, b, "web") },
		"deploy-status": func(c *Collector, b *bytes.Buffer) error { return c.DeployStatus(ctx, b, "web", id) },
		"releases":      func(c *Collector, b *bytes.Buffer) error { return c.Releases(ctx, b, "web") },
		"history":       func(c *Collector, b *bytes.Buffer) error { return c.History(ctx, b, "web", "") },
		"info":          func(c *Collector, b *bytes.Buffer) error { return c.Info(ctx, b) },
	} {
		o, err := h.out(verb)
		if err != nil {
			t.Fatal(name, err)
		}
		if err := outtest.Check([]byte(o)); err != nil {
			t.Errorf("%s: %v", name, err)
		}
		if !strings.Contains(o, "[31m") {
			t.Errorf("%s: the hostile text is not shown: %q", name, o)
		}
	}
}

// StatusVia relays tandod's answer as it is (tandod's out.Writer cleaned it): once, unchanged;
// without an answer it collects itself. The answer is asked for only as root.
func TestStatusVia(t *testing.T) {
	h := newHost(t)
	h.euid = 0
	h.app("web", "port=4100\n", "")
	body := []byte("host\tfrom\ttandod\napp\tweb\t-\n")
	var asked []string
	remote := func(ok bool) Remote {
		return func(ctx context.Context, app string) ([]byte, bool) { asked = append(asked, app); return body, ok }
	}
	var trace bytes.Buffer
	o, err := h.out(func(c *Collector, b *bytes.Buffer) error {
		c.Trace = &trace
		return c.StatusVia(context.Background(), b, "web", remote(true))
	})
	if err != nil || o != string(body) || trace.String() != "tando-status: via tandod\n" || len(asked) != 1 || asked[0] != "web" {
		t.Fatalf("relay: %q %v %q %q", o, err, trace.String(), asked)
	}
	trace.Reset()
	o, _ = h.out(func(c *Collector, b *bytes.Buffer) error {
		c.Trace = &trace
		return c.StatusVia(context.Background(), b, "", remote(false))
	})
	if !strings.HasPrefix(o, "host\tbox\t") || trace.String() != "tando-status: direct\n" {
		t.Fatalf("fallback: %q %q", o, trace.String())
	}
	h.euid = 1000
	asked = nil
	h.out(func(c *Collector, b *bytes.Buffer) error {
		return c.StatusVia(context.Background(), b, "", remote(true))
	})
	if asked != nil {
		t.Error("asked tandod without root")
	}
}

func TestAgentEnv(t *testing.T) {
	env := map[string]string{"LANG": "C.UTF-8", "LC_ALL": "x y", "LC_CTYPE": "a\x1bb", "SUDO_USER": "ann", "HOME": "/root", "SUDO_UID": ""}
	got := AgentEnv(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if strings.Join(got, " ") != "PATH="+SecurePath+" LANG=C.UTF-8 SUDO_USER=ann SUDO_UID=" {
		t.Errorf("%q", got)
	}
}
