package offsite

import (
	"bytes"
	"context"
	"crypto/rand"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/out"
	"tando/srv/internal/out/outtest"
	"tando/srv/internal/run"
)

// host is a fake server: temp directories for /opt/tando, /var/lib/tando, /var/backups/tando
// and /etc/systemd/system, a clock that can move (and the fake store's with it, as two machines
// whose clocks agree), a runner that records systemctl.
type host struct {
	t     *testing.T
	f     *fakeS3
	o     Offsite
	shift time.Duration
	mu    sync.Mutex
	runs  []string
}

func newHost(t *testing.T) *host {
	h := &host{t: t, f: newFakeS3(t)}
	d := t.TempDir()
	for _, x := range []string{"opt/apps", "lib", "backups", "units"} {
		os.MkdirAll(filepath.Join(d, x), 0o755)
	}
	e := env.Env{Root: filepath.Join(d, "opt"), Lib: filepath.Join(d, "lib"), EUID: 0,
		Now: func() time.Time { return time.Now().Add(h.shift) },
		Run: run.Func(func(ctx context.Context, c run.Cmd) ([]byte, error) {
			h.mu.Lock()
			h.runs = append(h.runs, strings.Join(c.Argv, " "))
			h.mu.Unlock()
			return nil, nil
		})}
	h.o = New(e, "9.9.9")
	h.o.Backups, h.o.Units, h.o.Hostname = filepath.Join(d, "backups"), filepath.Join(d, "units"), "testvm"
	h.o.HTTP, h.o.Sleep, h.o.Tries, h.o.Owner = h.f.srv.Client(), noSleep, 3, os.Getuid()
	return h
}

func (h *host) advance(d time.Duration) { h.shift += d; h.f.skew = h.shift }

func (h *host) settings(extra ...string) string {
	s := "endpoint=" + h.f.srv.URL + "\nbucket=" + h.f.bucket + "\naccess_key_id=" + h.f.access + "\nsecret_access_key=" + h.f.secret + "\n"
	for _, e := range extra {
		s += e + "\n"
	}
	return s
}

func (h *host) set(extra ...string) (map[string]string, error) {
	var b bytes.Buffer
	w := out.New(&b)
	err := h.o.Set(context.Background(), w, strings.NewReader(h.settings(extra...)))
	w.Flush()
	m, _ := kvfile.Parse(bytes.NewReader(b.Bytes()))
	return m, err
}

func (h *host) do(fn func(w *out.Writer) error) (string, error) {
	var b bytes.Buffer
	w := out.New(&b)
	err := fn(w)
	w.Flush()
	return b.String(), err
}

func (h *host) app(name, conf, envf string) {
	d := filepath.Join(h.o.Env.Root, "apps", name)
	os.MkdirAll(d, 0o755)
	os.WriteFile(filepath.Join(d, "app.conf"), []byte(conf), 0o644)
	os.WriteFile(filepath.Join(d, "env"), []byte(envf), 0o640)
}

func (h *host) backup(app, id string, files map[string]string) {
	d := filepath.Join(h.o.Backups, app, id)
	os.MkdirAll(d, 0o700)
	os.WriteFile(filepath.Join(d, "meta"), []byte("kind="+backupKind(id)+"\ncreated="+itoa(backupTime(id))+"\n"), 0o600)
	for n, c := range files {
		os.WriteFile(filepath.Join(d, n), []byte(c), 0o600)
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func idAt(t time.Time, kind string) string { return t.UTC().Format("20060102-150405") + "-" + kind }

func (h *host) push(app, id string) error {
	_, err := h.do(func(w *out.Writer) error { return h.o.Push(context.Background(), w, app, id) })
	return err
}

func (h *host) state(app, id string) map[string]string { return h.o.loadBackupState(app, id) }

func TestSetPushFetch(t *testing.T) {
	h := newHost(t)
	h.app("shop", "recipe=node\nport=4100\ndatabase=postgres\ndomains=shop.example.com|redirect\norigin=me@mac:/src/shop\nstart=node server.js\n",
		"API_TOKEN=\"tok\\\"en-PLAINTEXT-ENV\"\nDATABASE_URL=\"postgres://x\"\nPORT=\"4100\"\n")
	old := idAt(time.Now().Add(-48*time.Hour), "daily")
	h.backup("shop", old, map[string]string{"data.tar.gz": "OLD-DATA"})
	m, err := h.set()
	if err != nil {
		t.Fatal(err)
	}
	if m["saved"] != "1" || m["key_new"] != "1" || !strings.HasPrefix(m["key"], "tando-key-") || m["queued"] != "1" || !ValidHostID(m["host_id"]) {
		t.Fatalf("set: %v", m)
	}
	if fi, _ := os.Stat(h.o.Conf); fi.Mode().Perm() != 0o600 {
		t.Fatal("offsite.conf not 600")
	}
	if fi, _ := os.Stat(h.o.KeyFile); fi.Mode().Perm() != 0o600 {
		t.Fatal("offsite.key not 600")
	}
	if !strings.Contains(strings.Join(h.runs, ";"), "systemctl enable --now tando-offsite.timer") {
		t.Fatalf("timer not enabled: %v", h.runs)
	}
	// a second set does not make another key, and keeps the secret it was not given again
	m2, err := h.set()
	if err != nil || m2["key_new"] != "" || m2["key_id"] != m["key_id"] {
		t.Fatalf("second set: %v %v", m2, err)
	}
	// the queued old backup and a new one
	id := idAt(time.Now(), "manual")
	plain := "DATA-PLAINTEXT-MARKER-" + strings.Repeat("x", 3000)
	h.backup("shop", id, map[string]string{"data.tar.gz": plain, "db.dump": "DB-PLAINTEXT-MARKER"})
	if err := h.push("shop", id); err != nil {
		t.Fatal(err)
	}
	if err := h.push("shop", old); err != nil {
		t.Fatal(err)
	}
	st := h.state("shop", id)
	if st["state"] != "uploaded" || st["holds"] != "data db config" {
		t.Fatalf("state %v", st)
	}
	key := "tando/" + m["host_id"] + "/shop/" + id + ".rbk"
	obj := h.f.get(key)
	for _, marker := range []string{"PLAINTEXT-MARKER", "PLAINTEXT-ENV", "node server.js"} {
		if obj == nil || bytes.Contains(obj, []byte(marker)) {
			t.Fatalf("object missing or holds %q in clear", marker)
		}
	}
	man, _ := kvfile.Parse(bytes.NewReader(h.f.get(strings.TrimSuffix(key, ".rbk") + ".manifest")))
	if man["kind"] != "manual" || man["encrypted"] != "1" || man["key_id"] != m["key_id"] || man["hostname"] != "testvm" {
		t.Fatalf("manifest %v", man)
	}
	if h.f.get("tando/"+m["host_id"]+"/shop/app.rbk") == nil {
		t.Fatal("no app.rbk")
	}
	// gone locally: ls says offsite only; fetch brings it back, byte for byte
	os.RemoveAll(filepath.Join(h.o.Backups, "shop", id))
	o, err := h.do(func(w *out.Writer) error { return h.o.Ls(context.Background(), w, "shop", "") })
	if err != nil || !strings.Contains(o, "offsite\t"+id+"\tmanual\t") || !strings.Contains(o, "\t0\n") {
		t.Fatalf("ls: %q %v", o, err)
	}
	if _, err := h.do(func(w *out.Writer) error { return h.o.Fetch(context.Background(), w, "shop", id, "") }); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(h.o.Backups, "shop", id, "data.tar.gz"))
	db, _ := os.ReadFile(filepath.Join(h.o.Backups, "shop", id, "db.dump"))
	if string(got) != plain || string(db) != "DB-PLAINTEXT-MARKER" {
		t.Fatal("fetched backup differs")
	}
	if _, err := os.Stat(filepath.Join(h.o.Backups, "shop", id, "fetched")); err != nil {
		t.Fatal("no fetched marker")
	}
	if fi, _ := os.Stat(filepath.Join(h.o.Backups, "shop", id)); fi.Mode().Perm() != 0o700 {
		t.Fatal("fetched directory not 700")
	}
	// the brief: nothing waiting
	b, _ := kvfile.Load(h.o.briefPath("shop"))
	if b["enabled"] != "1" || b["pending"] != "0" || b["creds"] != "ok" || num(b["last_upload"]) == 0 {
		t.Fatalf("brief %v", b)
	}
	if h.f.sigFails != 0 {
		t.Fatal("signature failures")
	}
}

// Swapping objects in the bucket (another app's backup under this one's name) is refused.
func TestObjectSwapRefused(t *testing.T) {
	h := newHost(t)
	m, _ := h.set()
	a, b := idAt(time.Now(), "manual"), idAt(time.Now().Add(time.Second), "manual")
	h.backup("one", a, map[string]string{"data.tar.gz": "one"})
	h.backup("two", b, map[string]string{"data.tar.gz": "two"})
	h.push("one", a)
	h.push("two", b)
	p := "tando/" + m["host_id"]
	h.f.mu.Lock()
	h.f.objs[p+"/two/"+b+".rbk"] = h.f.objs[p+"/one/"+a+".rbk"]
	delete(h.f.objs, p+"/two/"+b+".manifest")
	h.f.mu.Unlock()
	os.RemoveAll(filepath.Join(h.o.Backups, "two", b))
	_, err := h.do(func(w *out.Writer) error { return h.o.Fetch(context.Background(), w, "two", b, "") })
	if err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("swapped object: %v", err)
	}
	if _, err := os.Stat(filepath.Join(h.o.Backups, "two", b)); err == nil {
		t.Fatal("a refused fetch left a backup")
	}
}

// A plaintext object planted in the bucket is refused while encryption is on.
func TestPlaintextRefused(t *testing.T) {
	h := newHost(t)
	m, _ := h.set()
	id := idAt(time.Now(), "manual")
	var b bytes.Buffer
	writeBundle(&b, []entry{{name: "meta", data: []byte("kind=manual\n"), size: 12}})
	h.f.mu.Lock()
	h.f.objs["tando/"+m["host_id"]+"/shop/"+id+".rbk"] = h.f.store(b.Bytes())
	h.f.mu.Unlock()
	_, err := h.do(func(w *out.Writer) error { return h.o.Fetch(context.Background(), w, "shop", id, "") })
	if err == nil || !strings.Contains(err.Error(), "not encrypted") {
		t.Fatalf("plaintext object: %v", err)
	}
}

// encrypt=off: plaintext objects, readable back
func TestEncryptOff(t *testing.T) {
	h := newHost(t)
	m, err := h.set("encrypt=off")
	if err != nil || m["key"] != "" {
		t.Fatalf("%v %v", m, err)
	}
	id := idAt(time.Now(), "manual")
	h.backup("shop", id, map[string]string{"data.tar.gz": "CLEAR"})
	if err := h.push("shop", id); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(h.f.get("tando/"+m["host_id"]+"/shop/"+id+".rbk"), []byte("CLEAR")) {
		t.Fatal("encrypt=off encrypted anyway")
	}
	os.RemoveAll(filepath.Join(h.o.Backups, "shop", id))
	if _, err := h.do(func(w *out.Writer) error { return h.o.Fetch(context.Background(), w, "shop", id, "") }); err != nil {
		t.Fatal(err)
	}
}

// Wrong credentials, wrong bucket, a skewed clock: set says which, saves nothing, never shows the secret.
func TestSetErrors(t *testing.T) {
	for _, tc := range []struct {
		name, extra, want string
		skew              time.Duration
	}{
		{"secret", "secret_access_key=wrong-secret-value", "secret access key does not match", 0},
		{"key id", "access_key_id=AKIDWRONG123", "does not know this access key id", 0},
		{"bucket", "bucket=nope", "no such bucket", 0},
		{"clock", "", "clock", 20 * time.Minute},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newHost(t)
			h.f.skew = tc.skew
			var b bytes.Buffer
			w := out.New(&b)
			err := h.o.Set(context.Background(), w, strings.NewReader(h.settings(tc.extra)))
			w.Flush()
			all := b.String() + " " + errString(err)
			if err == nil || !strings.Contains(all, tc.want) || !strings.Contains(errString(err), "nothing was saved") {
				t.Fatalf("got %q", all)
			}
			if strings.Contains(all, h.f.secret) || strings.Contains(all, "wrong-secret-value") {
				t.Fatal("the secret is in the output")
			}
			if _, err := os.Stat(h.o.Conf); err == nil {
				t.Fatal("saved anyway")
			}
		})
	}
	h := newHost(t)
	h.f.fault = func(w http.ResponseWriter, r *http.Request, n int) bool {
		if r.Method == "DELETE" {
			s3err(w, 403, "AccessDenied")
			return true
		}
		return false
	}
	_, err := h.set()
	if err == nil || !strings.Contains(err.Error(), "delete failed") || !strings.Contains(err.Error(), "permission") {
		t.Fatalf("no delete permission: %v", err)
	}
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// A failed upload is recorded, retried by sync once due, and the brief goes late after
// alert_hours; credentials that stop working show as failing.
func TestSyncRetriesAndBrief(t *testing.T) {
	h := newHost(t)
	if _, err := h.set("alert_hours=2"); err != nil {
		t.Fatal(err)
	}
	down := true
	h.f.fault = func(w http.ResponseWriter, r *http.Request, n int) bool {
		if down && r.Method != "GET" {
			s3err(w, 500, "InternalError")
			return true
		}
		return false
	}
	id := idAt(time.Now(), "daily")
	h.backup("shop", id, map[string]string{"data.tar.gz": "d"})
	if err := h.push("shop", id); err == nil {
		t.Fatal("push succeeded while the store fails")
	}
	st := h.state("shop", id)
	if st["state"] != "failed" || st["tries"] != "1" || num(st["next_try"]) <= time.Now().Unix() {
		t.Fatalf("state %v", st)
	}
	b, _ := kvfile.Load(h.o.briefPath("shop"))
	if s, _ := BriefState(b, time.Now().Unix()); s != "pending" || b["failed"] != "1" {
		t.Fatalf("brief %v", b)
	}
	if s, d := BriefState(b, time.Now().Unix()+3*3600); s != "late" || !strings.Contains(d, id) {
		t.Fatalf("late: %s %s", s, d)
	}
	// not due yet: sync leaves it
	sync := func() string {
		o, _ := h.do(func(w *out.Writer) error { return h.o.Sync(context.Background(), w, false) })
		return o
	}
	if o := sync(); !strings.Contains(o, "uploaded=0") {
		t.Fatalf("sync before due: %s", o)
	}
	down = false
	h.advance(10 * time.Minute)
	if o := sync(); !strings.Contains(o, "uploaded=1") {
		t.Fatalf("sync after due: %s", o)
	}
	if h.state("shop", id)["state"] != "uploaded" {
		t.Fatal("not uploaded")
	}
	// credentials revoked
	h.f.fault = func(w http.ResponseWriter, r *http.Request, n int) bool {
		s3err(w, 403, "InvalidAccessKeyId")
		return true
	}
	sync()
	b, _ = kvfile.Load(h.o.briefPath("shop"))
	if s, d := BriefState(b, time.Now().Unix()); s != "failing" || !strings.Contains(d, "access key id") {
		t.Fatalf("revoked: %s %s", s, d)
	}
	o, _ := h.do(func(w *out.Writer) error { return h.o.Brief(w, "shop") })
	if !strings.HasPrefix(o, "offsite\tshop\tfailing\t") {
		t.Fatalf("brief verb: %q", o)
	}
	o, _ = h.do(func(w *out.Writer) error { return h.o.Doctor(context.Background(), w) })
	if !strings.Contains(o, "check\tfail\toffsite\t") || !strings.Contains(o, "recovery key\tnot confirmed saved") {
		t.Fatalf("doctor: %q", o)
	}
}

// A push killed mid-way leaves its upload id; the next push aborts that upload first.
func TestKilledUploadAborted(t *testing.T) {
	h := newHost(t)
	m, _ := h.set()
	h.o.PartSize = 64 << 10
	id := idAt(time.Now(), "manual")
	h.backup("shop", id, map[string]string{"data.tar.gz": strings.Repeat("z", 300<<10)})
	ctx, cancel := context.WithCancel(context.Background())
	h.f.fault = func(w http.ResponseWriter, r *http.Request, n int) bool {
		if r.URL.Query().Get("partNumber") == "3" {
			cancel() // the process "dies" during part 3
			time.Sleep(50 * time.Millisecond)
			return true
		}
		return false
	}
	_, err := h.do(func(w *out.Writer) error { return h.o.Push(ctx, w, "shop", id) })
	if err == nil {
		t.Fatal("push survived")
	}
	key := "tando/" + m["host_id"] + "/shop/" + id + ".rbk"
	if h.f.get(key) != nil {
		t.Fatal("a half object is visible")
	}
	// as if killed before its abort: an upload in progress recorded in the state
	h.f.fault = nil
	h.f.mu.Lock()
	h.f.uploads["up-left"] = &fakeUpload{key: key, parts: map[int]*fakeObj{}}
	h.f.mu.Unlock()
	st := h.state("shop", id)
	st["upload_id"] = "up-left"
	h.o.saveBackupState("shop", id, st)
	if err := h.push("shop", id); err != nil {
		t.Fatal(err)
	}
	if len(h.f.uploads) != 0 {
		t.Fatalf("uploads left: %v", h.f.uploads)
	}
	if h.state("shop", id)["state"] != "uploaded" {
		t.Fatal("not uploaded")
	}
}

// Rotation: new uploads use the new key; old objects still read; an imported key becomes current.
func TestKeyRotation(t *testing.T) {
	h := newHost(t)
	m, _ := h.set()
	a := idAt(time.Now(), "manual")
	h.backup("shop", a, map[string]string{"data.tar.gz": "A"})
	h.push("shop", a)
	o, err := h.do(func(w *out.Writer) error { return h.o.KeyRotate(w) })
	if err != nil {
		t.Fatal(err)
	}
	rot, _ := kvfile.Parse(strings.NewReader(o))
	if rot["key_id"] == m["key_id"] || rot["keys"] != "2" {
		t.Fatalf("rotate: %v", rot)
	}
	b := idAt(time.Now().Add(time.Second), "manual")
	h.backup("shop", b, map[string]string{"data.tar.gz": "B"})
	h.push("shop", b)
	man, _ := kvfile.Parse(bytes.NewReader(h.f.get("tando/" + m["host_id"] + "/shop/" + b + ".manifest")))
	if man["key_id"] != rot["key_id"] {
		t.Fatal("new upload not with the new key")
	}
	for _, id := range []string{a, b} {
		os.RemoveAll(filepath.Join(h.o.Backups, "shop", id))
		if _, err := h.do(func(w *out.Writer) error { return h.o.Fetch(context.Background(), w, "shop", id, "") }); err != nil {
			t.Fatalf("%s: %v", id, err)
		}
	}
	// a server with only the new key cannot read the old object, and says which key it needs
	h.o.KeyFile = filepath.Join(t.TempDir(), "k")
	h.do(func(w *out.Writer) error { return h.o.KeyImport(w, strings.NewReader(rot["key"])) })
	os.RemoveAll(filepath.Join(h.o.Backups, "shop", a))
	_, err = h.do(func(w *out.Writer) error { return h.o.Fetch(context.Background(), w, "shop", a, "") })
	if err == nil || !strings.Contains(err.Error(), m["key_id"]) || !strings.Contains(err.Error(), "--import") {
		t.Fatalf("missing old key: %v", err)
	}
	if _, err := h.do(func(w *out.Writer) error { return h.o.KeyImport(w, strings.NewReader("tando-key-nope")) }); err == nil {
		t.Fatal("bad key imported")
	}
	// show lists every key; saved marks them
	o, _ = h.do(func(w *out.Writer) error { return h.o.KeyShow(w) })
	if strings.Count(o, "\n") != 1 || !strings.Contains(o, rot["key"]) {
		t.Fatalf("show: %q", o)
	}
}

func TestPrune(t *testing.T) {
	day := time.Date(2026, 11, 17, 3, 0, 0, 0, time.UTC)
	var bs []remoteBackup
	for i := 0; i < 60; i++ {
		d := day.Add(-time.Duration(i) * 24 * time.Hour)
		bs = append(bs, remoteBackup{id: idAt(d, "daily"), modified: d})
	}
	for i := 0; i < 8; i++ {
		d := day.Add(-time.Duration(i)*time.Hour - time.Minute)
		bs = append(bs, remoteBackup{id: idAt(d, "predeploy"), modified: d})
	}
	bs = append(bs, remoteBackup{id: idAt(day.Add(-400*24*time.Hour), "final"), modified: day.Add(-400 * 24 * time.Hour)})
	keep := func(k Keep) int {
		del := map[string]bool{}
		for _, id := range prune(bs, k) {
			del[id] = true
		}
		return len(bs) - len(del)
	}
	if n := keep(DefaultKeep); n != 7+4+5+1 {
		t.Fatalf("default keeps %d", n)
	}
	if n := keep(Keep{Daily: 30, Monthly: 12, Other: 5, Min: 3}); n != 30+2+5+1 {
		// 60 days back from Nov 17: 30 daily, then the newest of October and of September, 5 predeploy, the final
		t.Fatalf("30 daily + 12 monthly keeps %d", n)
	}
	// a clock set back: the newest uploads have the oldest ids; keep_min keeps them anyway
	var skewed []remoteBackup
	for i := 0; i < 10; i++ {
		skewed = append(skewed, remoteBackup{id: idAt(day.Add(-time.Duration(i)*24*time.Hour), "daily"), modified: day.Add(-time.Duration(i) * 24 * time.Hour)})
	}
	for i := 0; i < 3; i++ {
		d := time.Date(2001, 1, 1+i, 0, 0, 0, 0, time.UTC)
		skewed = append(skewed, remoteBackup{id: idAt(d, "daily"), modified: day.Add(time.Duration(i+1) * time.Hour)})
	}
	del := strings.Join(prune(skewed, Keep{Daily: 7, Min: 3}), " ")
	if strings.Contains(del, "2001") {
		t.Fatalf("the newest uploads were deleted: %s", del)
	}
}

// sync's retention deletes only this server's objects, never another host's
func TestRetentionOwnHostOnly(t *testing.T) {
	h := newHost(t)
	m, _ := h.set("keep_daily=2", "keep_weekly=0", "keep_min=1")
	other := "tando/aaaaaaaaaaaa/shop/" + idAt(time.Now().Add(-90*24*time.Hour), "daily") + ".rbk"
	h.f.mu.Lock()
	h.f.objs[other] = h.f.store([]byte("x"))
	h.f.mu.Unlock()
	for i := 4; i >= 0; i-- { // (oldest first: the last upload is the newest backup)
		id := idAt(time.Now().Add(-time.Duration(i)*24*time.Hour), "daily")
		h.backup("shop", id, map[string]string{"data.tar.gz": "d"})
		if err := h.push("shop", id); err != nil {
			t.Fatal(err)
		}
	}
	o, _ := h.do(func(w *out.Writer) error { return h.o.Sync(context.Background(), w, false) })
	if !strings.Contains(o, "deleted=3") {
		t.Fatalf("sync: %s", o)
	}
	if h.f.get(other) == nil {
		t.Fatal("another host's object was deleted")
	}
	n := 0
	for _, k := range h.f.keys() {
		if strings.HasPrefix(k, "tando/"+m["host_id"]+"/shop/") && strings.HasSuffix(k, ".rbk") && !strings.HasSuffix(k, "app.rbk") {
			n++
		}
	}
	if n != 2 {
		t.Fatalf("%d backups left", n)
	}
	if h.f.get("tando/"+m["host_id"]+"/inventory.rbk") == nil || h.f.get("tando/"+m["host_id"]+"/host.manifest") == nil {
		t.Fatal("no inventory after sync")
	}
}

// Disaster recovery: a second server with the same bucket and key lists the first and reads
// its apps' settings and env.
func TestDisasterRecovery(t *testing.T) {
	h := newHost(t)
	h.app("shop", "recipe=node\nport=4100\ncreated=1\ndatabase=postgres\ndomains=shop.example.com|redirect b.example.org|off\norigin=me@mac:/src/shop\nstart=node server.js\njob.nightly=daily|node x.js\nuser=\n",
		"API_TOKEN=\"a\\\"b\\\\c\"\nDATABASE_URL=\"postgres://x\"\nPORT=\"4100\"\n")
	m, _ := h.set()
	id := idAt(time.Now(), "daily")
	h.backup("shop", id, map[string]string{"data.tar.gz": "d", "db.dump": "db"})
	h.push("shop", id)
	h.do(func(w *out.Writer) error { return h.o.Sync(context.Background(), w, false) })

	// the new server: same bucket, its own directories, the key imported
	n := newHost(t)
	n.f = h.f
	n.o.HTTP = h.f.srv.Client()
	n.o.KeyFile = filepath.Join(t.TempDir(), "key")
	if _, err := n.do(func(w *out.Writer) error { return n.o.KeyImport(w, strings.NewReader(m["key"])) }); err != nil {
		t.Fatal(err)
	}
	if _, err := n.set(); err != nil {
		t.Fatal(err)
	}
	o, err := n.do(func(w *out.Writer) error { return n.o.Hosts(context.Background(), w) })
	if err != nil || !strings.Contains(o, "host\t"+m["host_id"]+"\ttestvm\t") || !strings.Contains(o, "\tshop\n") {
		t.Fatalf("hosts: %q %v", o, err)
	}
	o, err = n.do(func(w *out.Writer) error { return n.o.DrPlan(context.Background(), w, m["host_id"], nil) })
	want := "app\tshop\tnode\tpostgres\t" + id + "\tshop.example.com|redirect,b.example.org|off\tme@mac:/src/shop\t0\n"
	if err != nil || o != want {
		t.Fatalf("plan:\n%q\n%q %v", o, want, err)
	}
	o, _ = n.do(func(w *out.Writer) error { return n.o.DrConf(context.Background(), w, m["host_id"], "shop") })
	if o != "database=postgres\njob.nightly=daily|node x.js\nrecipe=node\nstart=node server.js\n" {
		t.Fatalf("conf: %q", o)
	}
	o, _ = n.do(func(w *out.Writer) error { return n.o.DrEnv(context.Background(), w, m["host_id"], "shop") })
	if o != "API_TOKEN=a\"b\\c\n" {
		t.Fatalf("env: %q", o)
	}
	if _, err := n.do(func(w *out.Writer) error { return n.o.Fetch(context.Background(), w, "shop", id, m["host_id"]) }); err != nil {
		t.Fatal(err)
	}
	if st := n.state("shop", id); st["source"] != m["host_id"] {
		t.Fatalf("fetched state %v", st)
	}
	// a fetched backup is not uploaded again under the new host id
	n.do(func(w *out.Writer) error { return n.o.Sync(context.Background(), w, false) })
	for _, k := range h.f.keys() {
		if strings.Contains(k, "/shop/"+id) && !strings.Contains(k, m["host_id"]) {
			t.Fatalf("re-uploaded: %s", k)
		}
	}
	if _, err := n.do(func(w *out.Writer) error { return n.o.DrPlan(context.Background(), w, m["host_id"], []string{"nope"}) }); err == nil {
		t.Fatal("unknown app accepted")
	}
	// without the key: a clear message
	x := newHost(t)
	x.f = h.f
	x.o.HTTP = h.f.srv.Client()
	x.set()
	if _, err := x.do(func(w *out.Writer) error { return x.o.DrPlan(context.Background(), w, m["host_id"], nil) }); err == nil || !strings.Contains(err.Error(), "--import") {
		t.Fatalf("no key: %v", err)
	}
}

func TestValidation(t *testing.T) {
	h := newHost(t)
	h.set()
	for _, args := range [][2]string{{"../x", "20261117-010101-daily"}, {"shop", "../../etc"}, {"shop", "20261117-010101-evil"}, {"Shop", "20261117-010101-daily"}} {
		if err := h.push(args[0], args[1]); err == nil {
			t.Errorf("push %v accepted", args)
		}
		if _, err := h.do(func(w *out.Writer) error { return h.o.Fetch(context.Background(), w, args[0], args[1], "") }); err == nil {
			t.Errorf("fetch %v accepted", args)
		}
	}
	if _, err := h.do(func(w *out.Writer) error {
		return h.o.Fetch(context.Background(), w, "shop", "20261117-010101-daily", "../x")
	}); err == nil {
		t.Error("bad host accepted")
	}
	// a link where a backup file should be: refused
	id := idAt(time.Now(), "manual")
	h.backup("shop", id, nil)
	os.Remove(filepath.Join(h.o.Backups, "shop", id, "meta"))
	os.Symlink("/etc/passwd", filepath.Join(h.o.Backups, "shop", id, "meta"))
	if err := h.push("shop", id); err == nil || !strings.Contains(err.Error(), "symbolic link") {
		t.Fatalf("symlink: %v", err)
	}
	h.o.Env.EUID = 1000
	if err := h.push("shop", id); err != errRoot {
		t.Fatal("not root accepted")
	}
}

// Hostile bytes in the state files and the bucket's answers come out cleaned.
func TestOutputClean(t *testing.T) {
	h := newHost(t)
	h.set()
	os.WriteFile(h.o.briefPath("shop"), []byte("enabled=1\ncreds=failing\ncreds_error="+outtest.Hostile+"\npending=1\n"), 0o644)
	o, _ := h.do(func(w *out.Writer) error { return h.o.Brief(w, "") })
	if err := outtest.Check([]byte(o)); err != nil || o == "" {
		t.Fatalf("brief: %v %q", err, o)
	}
	h.f.mu.Lock()
	h.f.objs["tando/abcdefabcdef/host.manifest"] = h.f.store([]byte("hostname=" + outtest.Hostile + "\napps=a b\n"))
	h.f.mu.Unlock()
	o, _ = h.do(func(w *out.Writer) error { return h.o.Hosts(context.Background(), w) })
	if err := outtest.Check([]byte(o)); err != nil || !strings.Contains(o, "abcdefabcdef") {
		t.Fatalf("hosts: %v %q", err, o)
	}
	_ = rand.Reader
}
