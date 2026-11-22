package ctl

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestAddrAllowed(t *testing.T) {
	var p FetchPolicy
	for _, s := range []string{"127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254",
		"100.64.0.1", "0.0.0.0", "::1", "fe80::1", "fd00:ec2::254", "::ffff:127.0.0.1", "::ffff:169.254.169.254",
		"224.0.0.1", "255.255.255.255", "::", "64:ff9b::a9fe:a9fe"} {
		if p.AddrAllowed(netip.MustParseAddr(s)) {
			t.Errorf("%s: allowed, want refused", s)
		}
	}
	for _, s := range []string{"8.8.8.8", "2606:4700::1111"} {
		if !p.AddrAllowed(netip.MustParseAddr(s)) {
			t.Errorf("%s: refused, want allowed", s)
		}
	}
	p.Allow = []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")}
	if !p.AddrAllowed(netip.MustParseAddr("127.0.0.1")) || p.AddrAllowed(netip.MustParseAddr("127.0.0.2")) {
		t.Error("the allowlist admits exactly what it names")
	}
}

func TestCheckURL(t *testing.T) {
	for _, s := range []string{"http://example.com/a", "ftp://x/a", "https://", "https://u:p@example.com/a",
		"file:///etc/passwd", "https://exa mple.com/", "https://example.com/\n", "//example.com/a", strings.Repeat("a", 3000)} {
		if _, err := CheckURL(s); err == nil {
			t.Errorf("%q: accepted", s)
		}
	}
	if _, err := CheckURL("https://artifacts.example.com:8443/a/b.tar.gz?sig=x"); err != nil {
		t.Error(err)
	}
}

func sha(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }

// tlsServer serves body at /a, a redirect to http at /r, and an over-long body at /long.
func tlsServer(t *testing.T, body []byte) (*httptest.Server, FetchPolicy) {
	t.Helper()
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/a":
			w.Write(body)
		case "/r":
			http.Redirect(w, r, "http://"+r.Host+"/a", http.StatusFound)
		case "/long":
			w.Write(append(body, body...)) // no Content-Length checked by the client: chunked? set none
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	pool := srv.Client().Transport.(*http.Transport).TLSClientConfig.RootCAs
	return srv, FetchPolicy{Roots: pool, Timeout: 10 * time.Second, MaxSize: 1 << 20}
}

func TestFetch(t *testing.T) {
	body := []byte("artifact bytes")
	srv, p := tlsServer(t, body)
	dir := t.TempDir()
	ctx := context.Background()
	// loopback: refused by the guard without the allowlist
	if _, err := p.Fetch(ctx, dir, srv.URL+"/a", int64(len(body)), sha(body)); !errors.Is(err, ErrAddr) && (err == nil || !strings.Contains(err.Error(), "address not allowed")) {
		t.Fatalf("loopback without allowlist: %v", err)
	}
	p.Allow = []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}
	f, err := p.Fetch(ctx, dir, srv.URL+"/a", int64(len(body)), sha(body))
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(f)
	f.Close()
	if !bytes.Equal(got, body) {
		t.Fatalf("got %q", got)
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 0 {
		t.Errorf("the download is not unlinked: %v", ents)
	}
	if _, err := p.Fetch(ctx, dir, srv.URL+"/a", int64(len(body)), sha([]byte("other"))); err == nil || !strings.Contains(err.Error(), "sha256") {
		t.Errorf("wrong sha256: %v", err)
	}
	if _, err := p.Fetch(ctx, dir, srv.URL+"/a", int64(len(body))-1, sha(body)); err == nil {
		t.Error("a body longer than the declared size was accepted")
	}
	if _, err := p.Fetch(ctx, dir, srv.URL+"/r", int64(len(body)), sha(body)); err == nil || !strings.Contains(err.Error(), "not https") {
		t.Errorf("redirect to http: %v", err)
	}
	if _, err := p.Fetch(ctx, dir, strings.Replace(srv.URL, "https", "http", 1)+"/a", int64(len(body)), sha(body)); err == nil {
		t.Error("http URL fetched")
	}
	if _, err := p.Fetch(ctx, dir, srv.URL+"/a", 2<<20, sha(body)); err == nil {
		t.Error("a size over the cap was accepted")
	}
	// an untrusted certificate
	p2 := p
	p2.Roots = nil
	if _, err := p2.Fetch(ctx, dir, srv.URL+"/a", int64(len(body)), sha(body)); err == nil {
		t.Error("a certificate of an unknown CA was accepted")
	}
}

type ent struct {
	name, link string
	typ        byte
	body       string
	mode       int64
}

func mktar(t *testing.T, es []ent) []byte {
	t.Helper()
	var b bytes.Buffer
	tw := tar.NewWriter(&b)
	for _, e := range es {
		h := &tar.Header{Name: e.name, Linkname: e.link, Typeflag: e.typ, Mode: e.mode, Size: int64(len(e.body))}
		if h.Mode == 0 {
			h.Mode = 0o644
		}
		if e.typ != tar.TypeReg {
			h.Size = 0
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if e.typ == tar.TypeReg {
			tw.Write([]byte(e.body))
		}
	}
	tw.Close()
	return b.Bytes()
}

const goodManifest = `{"v":1,"settings":{"recipe":"node","start":"node server.js","health":"/"}}`

func good() []ent {
	return []ent{
		{name: ManifestName, typ: tar.TypeReg, body: goodManifest},
		{name: "release/", typ: tar.TypeDir},
		{name: "release/server.js", typ: tar.TypeReg, body: "x", mode: 0o4755},
		{name: "release/lib/", typ: tar.TypeDir},
		{name: "release/lib/a.js", typ: tar.TypeReg, body: "a"},
		{name: "release/lib/self", typ: tar.TypeSymlink, link: "../server.js"},
	}
}

var lim = Limits{MaxEntries: 100, MaxBytes: 1 << 20}

func TestUnpackGood(t *testing.T) {
	dst := filepath.Join(t.TempDir(), "t")
	u, err := Unpack(context.Background(), bytes.NewReader(mktar(t, good())), dst, lim)
	if err != nil {
		t.Fatal(err)
	}
	if string(u.Manifest) != goodManifest {
		t.Errorf("manifest %q", u.Manifest)
	}
	fi, err := os.Stat(filepath.Join(dst, "release/server.js"))
	if err != nil || fi.Mode().Perm() != 0o755 || fi.Mode()&os.ModeSetuid != 0 {
		t.Errorf("server.js: %v %v (setuid dropped, 0755)", fi.Mode(), err)
	}
	if _, err := os.Stat(filepath.Join(dst, ManifestName)); err == nil {
		t.Error("the manifest is not written to disk")
	}
}

func TestUnpackMalicious(t *testing.T) {
	m := ent{name: ManifestName, typ: tar.TypeReg, body: goodManifest}
	r := ent{name: "release/", typ: tar.TypeDir}
	cases := map[string][]ent{
		"absolute":           {m, r, {name: "/etc/cron.d/x", typ: tar.TypeReg, body: "x"}},
		"dotdot":             {m, r, {name: "release/../../x", typ: tar.TypeReg, body: "x"}},
		"dotdot-clean":       {m, r, {name: "release/a/../../x", typ: tar.TypeReg, body: "x"}},
		"outside release":    {m, r, {name: "other.txt", typ: tar.TypeReg, body: "x"}},
		"symlink absolute":   {m, r, {name: "release/l", typ: tar.TypeSymlink, link: "/etc/shadow"}},
		"symlink escape":     {m, r, {name: "release/a/", typ: tar.TypeDir}, {name: "release/a/l", typ: tar.TypeSymlink, link: "../../../etc"}},
		"symlink to top":     {m, r, {name: "release/l", typ: tar.TypeSymlink, link: "../tando-artifact.json"}},
		"write through link": {m, r, {name: "release/l", typ: tar.TypeSymlink, link: "."}, {name: "release/l/x", typ: tar.TypeReg, body: "x"}},
		"link then dir":      {m, r, {name: "release/d", typ: tar.TypeSymlink, link: "."}, {name: "release/d/", typ: tar.TypeDir}},
		"hardlink":           {m, r, {name: "release/a", typ: tar.TypeReg, body: "x"}, {name: "release/h", typ: tar.TypeLink, link: "release/a"}},
		"hardlink out":       {m, r, {name: "release/h", typ: tar.TypeLink, link: "/etc/shadow"}},
		"char device":        {m, r, {name: "release/null", typ: tar.TypeChar}},
		"block device":       {m, r, {name: "release/sda", typ: tar.TypeBlock}},
		"fifo":               {m, r, {name: "release/p", typ: tar.TypeFifo}},
		"duplicate":          {m, r, {name: "release/a", typ: tar.TypeReg, body: "x"}, {name: "release/a", typ: tar.TypeReg, body: "y"}},
		"file then below":    {m, r, {name: "release/a", typ: tar.TypeReg, body: "x"}, {name: "release/a/b", typ: tar.TypeReg, body: "y"}},
		"no manifest":        {r, {name: "release/a", typ: tar.TypeReg, body: "x"}},
		"no release":         {m},
		"manifest symlink":   {{name: ManifestName, typ: tar.TypeSymlink, link: "/etc/passwd"}, r},
		"control char":       {m, r, {name: "release/a\nb", typ: tar.TypeReg, body: "x"}},
		"two manifests":      {m, m, r},
		"release is a file":  {m, {name: "release", typ: tar.TypeReg, body: "x"}},
		"release is a link":  {m, {name: "release", typ: tar.TypeSymlink, link: "/"}},
	}
	for name, es := range cases {
		dst := filepath.Join(t.TempDir(), "t")
		if _, err := Unpack(context.Background(), bytes.NewReader(mktar(t, es)), dst, lim); err == nil {
			t.Errorf("%s: unpacked, want refused", name)
		}
	}
}

func TestUnpackLimits(t *testing.T) {
	es := []ent{{name: ManifestName, typ: tar.TypeReg, body: goodManifest}, {name: "release/", typ: tar.TypeDir}}
	for i := 0; i < 150; i++ {
		es = append(es, ent{name: "release/f" + string(rune('a'+i%26)) + strings.Repeat("x", i/26), typ: tar.TypeReg, body: "1"})
	}
	if _, err := Unpack(context.Background(), bytes.NewReader(mktar(t, es)), filepath.Join(t.TempDir(), "t"), lim); err == nil || !strings.Contains(err.Error(), "entries") {
		t.Errorf("entries: %v", err)
	}
	// a decompression bomb: 64 MB of zeros, a few KB gzipped; the limit is 1 MB
	var tb bytes.Buffer
	tw := tar.NewWriter(&tb)
	tw.WriteHeader(&tar.Header{Name: ManifestName, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(goodManifest))})
	tw.Write([]byte(goodManifest))
	tw.WriteHeader(&tar.Header{Name: "release/", Typeflag: tar.TypeDir, Mode: 0o755})
	tw.WriteHeader(&tar.Header{Name: "release/zero", Typeflag: tar.TypeReg, Mode: 0o644, Size: 64 << 20})
	tw.Write(make([]byte, 64<<20))
	tw.Close()
	var gz bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&gz, gzip.BestCompression)
	zw.Write(tb.Bytes())
	zw.Close()
	if gz.Len() > 1<<20 {
		t.Fatalf("bomb is %d bytes", gz.Len())
	}
	f, _ := os.CreateTemp(t.TempDir(), "a")
	f.Write(gz.Bytes())
	f.Seek(0, 0)
	dst := filepath.Join(t.TempDir(), "t")
	if _, err := UnpackFile(context.Background(), nil, f, dst, lim); err == nil || !strings.Contains(err.Error(), "bytes") {
		t.Errorf("bomb: %v", err)
	}
	// not compressed at all
	f2, _ := os.CreateTemp(t.TempDir(), "a")
	f2.Write(mktar(t, good()))
	f2.Seek(0, 0)
	if _, err := UnpackFile(context.Background(), nil, f2, filepath.Join(t.TempDir(), "t"), lim); err == nil {
		t.Error("an uncompressed tar was accepted")
	}
}

func TestManifest(t *testing.T) {
	if _, err := ParseManifest([]byte(goodManifest)); err != nil {
		t.Fatal(err)
	}
	for _, b := range []string{
		`{"v":2,"settings":{}}`,
		`{"v":1,"settings":{"memory":"4G"}}`,
		`{"v":1,"settings":{"domain":"evil.example.com"}}`,
		`{"v":1,"settings":{"idle_stop":"off"}}`,
		`{"v":1,"settings":{"worker.q.memory":"2G"}}`,
		`{"v":1,"settings":{"recipe":"python"}}`,
		`{"v":1,"settings":{"recipe":"container","image":"x"}}`,
		`{"v":1,"settings":{"start":"a\nmemory=4G"}}`,
		`{"v":1,"settings":{},"extra":1}`,
		`{"v":1,"settings":{"preview_of":"other"}}`,
	} {
		if _, err := ParseManifest([]byte(b)); err == nil {
			t.Errorf("%s: accepted", b)
		}
	}
	m, _ := ParseManifest([]byte(`{"v":1,"settings":{"start":"node s.js","worker.q":"node q.js"}}`))
	in := configureInput(map[string]string{"memory": "512M", "port": "3001", "worker.q.memory": "128M", "worker.z.memory": "64M", "start": "old"}, m.Settings, nil)
	if in != "memory=512M\nstart=node s.js\nworker.q=node q.js\nworker.q.memory=128M\n" {
		t.Errorf("configure input:\n%s", in)
	}
}

// review findings (docs/CONTROL-PLANE.md): IPv4-compatible and Teredo IPv6, 4in6 allowlist
// entries, link chains, global headers counted, a directory entry after its files, no digest or
// status in what an app's principal sees, the allowlist only for the write principal, the cap
func TestReviewFetchUnpack(t *testing.T) {
	var p FetchPolicy
	for _, s := range []string{"::7f00:1", "::a9fe:a9fe", "2001::1", "2001:0:4136:e378:8000:63bf:3fff:fdd2"} {
		if p.AddrAllowed(netip.MustParseAddr(s)) {
			t.Errorf("%s: allowed, want refused", s)
		}
	}
	p.Allow = []netip.Prefix{netip.MustParsePrefix("::ffff:10.0.0.0/104")}
	if !p.AddrAllowed(netip.MustParseAddr("10.1.2.3")) || p.AddrAllowed(netip.MustParseAddr("192.168.1.1")) {
		t.Error("a 4in6 allowlist entry matches its IPv4 range")
	}
	m := ent{name: ManifestName, typ: tar.TypeReg, body: goodManifest}
	r := ent{name: "release/", typ: tar.TypeDir}
	chain := []ent{m, r, {name: "release/l1", typ: tar.TypeSymlink, link: "."},
		{name: "release/a/", typ: tar.TypeDir}, {name: "release/a/b/", typ: tar.TypeDir},
		{name: "release/a/b/l2", typ: tar.TypeSymlink, link: "../../l1/.."}}
	if _, err := Unpack(context.Background(), bytes.NewReader(mktar(t, chain)), filepath.Join(t.TempDir(), "t"), lim); err == nil {
		t.Error("a chain of links out of release/ was unpacked")
	}
	late := []ent{m, {name: "release/a/x", typ: tar.TypeReg, body: "x"}, {name: "release/a/", typ: tar.TypeDir}, r}
	if _, err := Unpack(context.Background(), bytes.NewReader(mktar(t, late)), filepath.Join(t.TempDir(), "t"), lim); err != nil {
		t.Errorf("a directory entry after its files: %v", err)
	}
	var b bytes.Buffer
	tw := tar.NewWriter(&b)
	for i := 0; i < 200; i++ {
		tw.WriteHeader(&tar.Header{Typeflag: tar.TypeXGlobalHeader, Name: "g", PAXRecords: map[string]string{"comment": "x"}})
	}
	tw.Close()
	if _, err := Unpack(context.Background(), bytes.NewReader(b.Bytes()), filepath.Join(t.TempDir(), "t"), lim); err == nil || !strings.Contains(err.Error(), "entries") {
		t.Errorf("global headers are not counted: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Unpack(ctx, bytes.NewReader(mktar(t, good())), filepath.Join(t.TempDir(), "t"), lim); err == nil {
		t.Error("a cancelled unpack went on")
	}
	// the digest of what was fetched is never told
	body := []byte("artifact bytes")
	srv, fp := tlsServer(t, body)
	fp.Allow = []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}
	_, err := fp.Fetch(context.Background(), t.TempDir(), srv.URL+"/a", int64(len(body)), sha([]byte("x")))
	if err == nil || strings.Contains(err.Error(), sha(body)) || strings.Contains(err.Error(), sha(body)[:16]) {
		t.Errorf("sha256 mismatch tells the digest: %v", err)
	}
	_, err = fp.Fetch(context.Background(), t.TempDir(), srv.URL+"/nope", 5, sha(body))
	fe, ok := err.(*FetchError)
	if !ok || strings.Contains(fe.Kind, "404") {
		t.Errorf("an app's principal would learn the status: %#v", err)
	}
}

func TestReviewPrincipals(t *testing.T) {
	c, _, serve := ctlHarness(t, nil)
	// an allowlist file that is not root's: the write principal's fetch policy reads it (and
	// refuses it), an app's never reads it at all
	os.MkdirAll(filepath.Join(c.Env.Root, "ctl"), 0o755)
	os.WriteFile(filepath.Join(c.Env.Root, "ctl", "fetch-allow"), []byte("10.0.0.0/8\n"), 0o644)
	if os.Geteuid() != 0 {
		if _, _, e := c.fetchPolicy(Ident{Mode: ModeWrite}); e == nil {
			t.Error("the write principal's policy did not read the allowlist")
		}
	}
	if p, _, e := c.fetchPolicy(Ident{Mode: ModeApp, App: "shop"}); e != nil || len(p.Allow) != 0 {
		t.Errorf("an app's principal gets the allowlist: %+v %v", p.Allow, e)
	}
	if p, _, _ := c.fetchPolicy(Ident{Mode: ModeApp, App: "shop"}); p.MaxSize != ArtifactMaxMB<<20 {
		t.Errorf("default artifact cap %d", p.MaxSize)
	}
	r := serve(shp, `{"v":1,"verb":"app.deploy","app":"shop","request_id":"deploy-big-1","args":{"url":"https://a.example.com/x.tar.gz","sha256":"`+strings.Repeat("a", 64)+`","size":`+strconv.Itoa(600<<20)+`}}`)
	if r.Error == nil || !strings.Contains(r.Error.Message, "ctl_artifact_max_mb") {
		t.Errorf("over the cap: %+v", r)
	}
	// the spec goes with the app; export to an app's principal has no URL query
	c.saveSpec("shop", Spec{Generation: 4, Artifact: &DeployArgs{URL: "https://s.example.com/a.tar.gz?X-Sig=secret", SHA256: strings.Repeat("a", 64), Size: 1}})
	r = serve(shp, `{"v":1,"verb":"app.export","app":"shop"}`)
	if b, _ := json.Marshal(r.Result); !r.OK || strings.Contains(string(b), "secret") || !strings.Contains(string(b), "a.tar.gz") {
		t.Errorf("export to the app: %s", b)
	}
	r = serve(wr, `{"v":1,"verb":"app.export","app":"shop"}`)
	if b, _ := json.Marshal(r.Result); !strings.Contains(string(b), "X-Sig=secret") {
		t.Errorf("export to write: %s", b)
	}
	r = serve(wr, `{"v":1,"verb":"app.destroy","app":"shop","request_id":"destroy-001","args":{"confirm":"shop"}}`)
	if _, err := os.Stat(c.specPath("shop")); !r.OK || err == nil {
		t.Errorf("the spec outlives the app: %+v", r)
	}
}
