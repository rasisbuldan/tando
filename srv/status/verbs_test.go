package status

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"

	"tando/srv/internal/bashread"
	"tando/srv/internal/fsinfo"
)

func testCert(t *testing.T, notAfter int64) string {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{SerialNumber: big.NewInt(7), Subject: pkix.Name{CommonName: "x"},
		NotBefore: time.Unix(1_700_000_000, 0), NotAfter: time.Unix(notAfter, 0)}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}

func TestCertExpiry(t *testing.T) {
	h := newHost(t)
	c := h.collector()
	eq(t, c.certExpiry("a.example.com"), "-")
	// Caddy's .crt may start with a key block: a throwaway one made here, never a real key
	keyBlock := string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: []byte{0, 0, 0}}))
	h.write("certs/issuer/a.example.com/a.example.com.crt", keyBlock+
		testCert(t, 1_850_000_000)+testCert(t, 1_999_999_999))
	eq(t, c.certExpiry("a.example.com"), "1850000000")
	h.write("certs/issuer/b.example.com/b.example.com.crt", "garbage\n")
	eq(t, c.certExpiry("b.example.com"), "-") // (the shell printed today's midnight)
	// the caddy user's tree: links are not followed
	h.write("secret.crt", testCert(t, 1_850_000_000))
	os.MkdirAll(h.path("certs/issuer/c.example.com"), 0o755)
	os.Symlink(h.path("secret.crt"), h.path("certs/issuer/c.example.com/c.example.com.crt"))
	eq(t, c.certExpiry("c.example.com"), "-")
	os.MkdirAll(h.path("elsewhere/d.example.com"), 0o755)
	h.write("elsewhere/d.example.com/d.example.com.crt", testCert(t, 1_850_000_000))
	os.Symlink(h.path("elsewhere"), h.path("certs/linked"))
	eq(t, c.certExpiry("d.example.com"), "-")
	eq(t, c.certExpiry("../secret"), "-")
}

func TestDeployStatus(t *testing.T) {
	ds := func(h *host, app, id string) (string, error) {
		return h.out(func(c *Collector, b *bytes.Buffer) error { return c.DeployStatus(context.Background(), b, app, id) })
	}
	const id = "20261114-170102"
	t.Run("running", func(t *testing.T) {
		h := newHost(t)
		h.euid = 0
		h.app("web", "port=4100\n", "phase=verify\ntarget="+id+"\n")
		act := "id=" + id + "\nphase=soak\nresult=running\nsoak=30\nsoak_end=1800000020\nstarted=1799999990\nstarted_ds=17999999900\nt_copy=0.4\nt_preflight=2.0\nt_switch=0.1\n"
		h.write("root/apps/web/activation", act)
		h.act["tando-web-act-"+id] = "active"
		got, err := ds(h, "web", id)
		if err != nil {
			t.Fatal(err)
		}
		// bash 5's order for these keys (seen on the test server)
		eq(t, got, rows("result=running", "id="+id, "t_switch=0.1", "phase=soak", "t_copy=0.4", "started_ds=17999999900",
			"t_preflight=2.0", "soak_end=1800000020", "soak=30", "started=1799999990", "link=http://web.example.org:8080"))
		if h.called(h.path("root/bin/tando-agent")) != 0 {
			t.Error("recovered a live activation")
		}
		// its cgroup has a process: systemctl is not asked
		h.write("cgroup/system.slice/tando-web-act-"+id+".service/cgroup.events", "populated 1\nfrozen 0\n")
		h.calls = nil
		ds(h, "web", id)
		if h.called("systemctl") != 0 {
			t.Errorf("asked systemctl: %v", h.calls)
		}
	})
	t.Run("dead activation is recovered", func(t *testing.T) {
		h := newHost(t)
		h.euid = 0
		h.program("tando-agent")
		h.app("web", "port=4100\n", "phase=verify\ntarget="+id+"\n")
		h.write("root/apps/web/activation", "id="+id+"\nresult=running\nphase=copy\n")
		h.write("root/apps/web/activation.log", "line 1\nbad \x1b[2J\x00 char\nunterminated")
		h.onRecover = func() {
			h.write("root/apps/web/activation", "id="+id+"\nresult=failed\nphase=done\nmessage=interrupted during copy\n")
			h.write("root/apps/web/state", "phase=idle\nstatus_"+id+"=bad\n")
		}
		got, _ := ds(h, "web", id)
		eq(t, got, rows("result=failed", "id="+id, "phase=done", "message=interrupted during copy", "link=http://web.example.org:8080",
			"log=line 1", "log=bad ?[2J char"))
		if h.called(h.path("root/bin/tando-agent")+" recover web") != 1 {
			t.Errorf("calls %v", h.calls)
		}
		// without root: no recovery
		h.euid = 1000
		h.write("root/apps/web/activation", "id="+id+"\nresult=running\n")
		h.calls = nil
		ds(h, "web", id)
		if len(h.calls) != 0 {
			t.Errorf("calls %v", h.calls)
		}
	})
	t.Run("overwritten: history has the end", func(t *testing.T) {
		h := newHost(t)
		h.app("web", "port=4100\n", "")
		h.write("root/apps/web/activation", "id=20261115-000000\nresult=ok\n")
		h.write("root/apps/web/history.tsv", tab("1", id, "deploy", "rolledback", "x")+"\n"+tab("2", id, "deploy", "ok-ish")+"\n"+tab("3", "other", "deploy", "failed"))
		got, _ := ds(h, "web", id)
		eq(t, got, rows("phase=done", "result=verified-ish", "link=http://web.example.org:8080"))
	})
	t.Run("queued", func(t *testing.T) {
		h := newHost(t)
		h.app("web", "port=4100\n", "phase=verify\ntarget=20261114-000000\nstatus_20261114-000000=\n")
		os.MkdirAll(h.path("root/apps/web/releases/"+id), 0o755)
		h.write("root/apps/web/activation", "id=20261114-000000\nphase=soak\nsoak_end=1800000025\n")
		got, _ := ds(h, "web", id)
		eq(t, got, rows("phase=queued", "result=running", "waiting_for=20261114-000000", "waiting_phase=soak", "waiting_left=25"))
		h.write("root/apps/web/state", "phase=rollback\nkind=rollback\ntarget=20261114-000000\n")
		got, _ = ds(h, "web", id)
		eq(t, got, rows("phase=queued", "result=running", "waiting_for=20261114-000000", "waiting_phase=rollback"))
		h.write("root/apps/web/state", "phase=idle\n")
		got, _ = ds(h, "web", id)
		eq(t, got, rows("phase=queued", "result=running"))
	})
	t.Run("done", func(t *testing.T) {
		h := newHost(t)
		h.app("web", "port=4100\n", "status_"+id+"=verified\n")
		got, _ := ds(h, "web", id)
		eq(t, got, rows("phase=done", "result=verified"))
		got, _ = ds(h, "web", "20261114-170103")
		eq(t, got, rows("phase=done", "result=unknown"))
	})
	t.Run("errors", func(t *testing.T) {
		h := newHost(t)
		h.app("web", "port=4100\n", "")
		for _, c := range []struct{ app, id, want string }{{"nope", "x", "no such app: nope"}, {"web", "x", "bad id"}, {"web", "", "bad id"}, {"", id, "invalid app name"}} {
			if _, err := ds(h, c.app, c.id); err == nil || err.Error() != c.want {
				t.Errorf("%v: %v", c, err)
			}
		}
	})
}

func TestBusy(t *testing.T) {
	busy := func(h *host) (string, error) {
		return h.out(func(c *Collector, b *bytes.Buffer) error { return c.Busy(context.Background(), b, "web") })
	}
	h := newHost(t)
	h.app("web", "port=4100\n", "phase=verify\ntarget=20261114-170102\n")
	h.euid = 1000
	if _, err := busy(h); err == nil || err.Error() != "this needs root (sudo)" {
		t.Fatalf("not root: %v", err)
	}
	h.euid = 0
	got, err := busy(h)
	if err != nil || got != "" {
		t.Fatalf("no lock file: %q %v", got, err)
	}
	h.write("root/apps/web/lock", "")
	if got, _ := busy(h); got != "" {
		t.Fatalf("free: %q", got)
	}
	f, _ := os.Open(h.path("root/apps/web/lock"))
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	h.write("root/apps/web/activation", "id=20261114-170102\nphase=soak\nsoak_end=1800000012\n")
	h.write("root/apps/web/lock.holder", "run-activation 123\n")
	h.write("root/apps/web/lock.wait.999999999", "")
	got, _ = busy(h)
	eq(t, got, rows("busy=20261114-170102", "busy_phase=soak", "busy_left=12", "busy_soak=30", "busy_waiting=0", "busy_by=a deploy"))
	if fsinfo.ExistsFollow(h.path("root/apps/web/lock.wait.999999999")) {
		t.Error("stale wait marker kept")
	}
	os.MkdirAll(h.path("proc/4242"), 0o755)
	h.write("root/apps/web/lock.wait.4242", "")
	h.write("root/apps/web/state", "phase=idle\n")
	h.write("root/apps/web/app.conf", "port=4100\nsoak=5\n")
	h.write("root/apps/web/lock.holder", "adopt-apply 1")
	got, _ = busy(h)
	eq(t, got, rows("busy=-", "busy_phase=other", "busy_left=-", "busy_soak=5", "busy_waiting=1", "busy_by=an adopt step"))
	for v, want := range map[string]string{"stop": "a stop", "backup-restore": "a restore", "deploy-status": "a recovery check", "": "another operation", "destroy": "destroy"} {
		h.write("root/apps/web/lock.holder", v+" 1\n")
		if got := lockHolder(h.path("root/apps/web")); got != want {
			t.Errorf("%q: %q", v, got)
		}
	}
}

func TestInfo(t *testing.T) {
	h := newHost(t)
	h.euid = 0
	h.write("root/VERSION", "0.1.0\n\n")
	h.write("root/bin/tando-agent", "hello\n")
	h.write("root/host.conf", "apps_domain=example.org\ntls=internal\npostgres=16\n")
	h.programs["node"] = "v24.1.0\n"
	h.programs["caddy"] = "v2.6.2 h1:abc\n"
	h.programs["getconf"] = "glibc 2.39\n"
	info := func() string {
		got, err := h.out(func(c *Collector, b *bytes.Buffer) error {
			c.ToolPath = h.path("tools")
			return c.Info(context.Background(), b)
		})
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	h.write("tools/node", "")
	h.write("tools/caddy", "")
	h.write("tools/getconf", "")
	os.Chmod(h.path("tools/getconf"), 0o755)
	os.Chmod(h.path("tools/node"), 0o755)
	os.Chmod(h.path("tools/caddy"), 0o755)
	want := rows("version=0.1.0", "proto=2", "arch="+machine(), "libc=glibc", "glibc=2.39", "apps_domain=example.org", "tls=internal", "sum=3015617425",
		"podman=no", "python=no", "node=24.1.0", "caddy=2.6.2", "postgres=16", "public_port=", "ip=10.0.0.2",
		"addrs=10.0.0.2 2001:db8::2 ", "domain_tls=internal")
	eq(t, info(), want)
	if n := h.called(h.path("tools/node")); n != 1 {
		t.Errorf("node ran %d times", n)
	}
	eq(t, info(), want) // from the cache
	if n := h.called(h.path("tools/node")); n != 1 {
		t.Errorf("node ran %d times after the cache", n)
	}
	// a new node binary: asked again
	h.programs["node"] = "v25.0.0\n"
	os.Remove(h.path("tools/node"))
	h.write("tools/node", "new")
	os.Chmod(h.path("tools/node"), 0o755)
	if got := info(); !strings.Contains(got, "\nnode=25.0.0\n") {
		t.Errorf("after an upgrade: %s", got)
	}
	if fi, err := os.Stat(h.path("lib/status/tools")); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("cache file: %v %v", fi, err)
	}
}

func TestBashOrder(t *testing.T) {
	keys := strings.Fields("a aa ab ac b c d e f g h i id j k l m message n o p phase q r result s soak soak_end started started_ds t t_build t_copy t_preflight t_switch t_upload t_verify u v venv w x y z")
	want := "result t_verify id t_switch ab ac aa phase t_copy started_ds t_preflight z y t_build x w v u t s r q p o n m l k j i h g f e d c b a message venv soak_end soak started t_upload"
	if got := strings.Join(bashOrder(keys), " "); got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
}

func TestParseKV(t *testing.T) {
	k := parseKV([]byte("a=1\nb=x=y=\nc=\r\n=no\nnoeq\nd=1\x00 2\na=again\ne=unterminated"))
	if strings.Join(k.order, ",") != "a,b,c,d" || k.get("a") != "again" || k.get("b") != "x=y=" || k.get("c") != "\r" ||
		k.get("d") != "1 2" || k.has("e") || k.or("zz", "def") != "def" || k.or("c", "def") != "\r" {
		t.Errorf("%+v", k)
	}
}

func TestReadTabWords(t *testing.T) {
	got := bashread.Fields("\ta\t\tb\tc d\t\te\t", 3)
	if strings.Join(got, "|") != "a|b|c d\t\te" {
		t.Errorf("%q", got)
	}
	got = bashread.Fields("a", 3)
	if strings.Join(got, "|") != "a||" {
		t.Errorf("%q", got)
	}
	if w := words(" a\tb\r c\n\nd e "); strings.Join(w, "|") != "a|b\r|c|d e" {
		t.Errorf("%q", w)
	}
}

func TestHostFacts(t *testing.T) {
	for in, want := range map[string]int{"0": 1, "0-3": 4, "0-1,3": 3, "0,2-5,7": 6, "": 0} {
		if got := cpusOnline(in); got != want {
			t.Errorf("%q: %d", in, got)
		}
	}
}
