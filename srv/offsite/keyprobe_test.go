package offsite

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/out"
)

func (h *host) test() (string, error) {
	return h.do(func(w *out.Writer) error { return h.o.Test(context.Background(), w) })
}

func (h *host) deny(mode string) {
	h.f.mu.Lock()
	h.f.deny = mode
	h.f.mu.Unlock()
}

func (h *host) probeObjects() []string {
	var r []string
	for _, k := range h.f.keys() {
		if strings.Contains(k, ".tando-key-test/") {
			r = append(r, k)
		}
	}
	return r
}

// A key with every permission: the test says, as a finding and not a failure, that it can replace
// and delete; nothing is left in the bucket.
func TestProbeKeyThatCanDelete(t *testing.T) {
	h := newHost(t)
	if _, err := h.set(); err != nil {
		t.Fatal(err)
	}
	o, err := h.test()
	if err != nil {
		t.Fatalf("%v\n%s", err, o)
	}
	for _, want := range []string{"step=overwrite warn allowed: this key can replace", "step=delete warn " + textCanDelete, "step=clock ok"} {
		if !strings.Contains(o, want) {
			t.Errorf("lacks %q:\n%s", want, o)
		}
	}
	if l := h.probeObjects(); len(l) != 0 {
		t.Errorf("left behind: %v", l)
	}
	if hs := h.o.loadHostState(); hs["key_delete"] != "allowed" || hs["key_overwrite"] != "allowed" || hs["key_checked"] == "" {
		t.Errorf("host state: %v", hs)
	}
}

// A key that may not delete: set and test pass and say so; one small, plainly named object
// stays and is used again by every later check.
func TestProbeKeyThatCannotDelete(t *testing.T) {
	h := newHost(t)
	h.deny("delete")
	m, err := h.set()
	if err != nil {
		t.Fatalf("set with a key that may not delete: %v", err)
	}
	want := "tando/" + m["host_id"] + "/.tando-key-test/can-this-key-delete-or-overwrite.txt"
	for i := 0; i < 3; i++ {
		o, err := h.test()
		if err != nil || !strings.Contains(o, "step=delete ok "+textNoDelete) {
			t.Fatalf("test %d: %v\n%s", i, err, o)
		}
		if strings.Contains(o, " fail ") {
			t.Fatalf("a failed step:\n%s", o)
		}
	}
	l := h.probeObjects()
	if len(l) != 1 || l[0] != want {
		t.Fatalf("the test objects after 4 checks: %v, want only %s", l, want)
	}
	if b := h.f.get(want); len(b) > 512 || !strings.Contains(string(b), "safe to delete") {
		t.Errorf("the leftover is not small or does not say what it is: %d bytes %q", len(b), b)
	}
	if hs := h.o.loadHostState(); hs["key_delete"] != "refused" || hs["key_overwrite"] != "allowed" {
		t.Errorf("host state: %v", hs)
	}
	// the key gets its permission back: the leftover goes
	h.deny("")
	if o, err := h.test(); err != nil || !strings.Contains(o, "step=delete warn allowed") {
		t.Fatalf("%v\n%s", err, o)
	}
	if l := h.probeObjects(); len(l) != 0 {
		t.Errorf("left behind: %v", l)
	}
}

// A lock on the bucket (R2's answer: 409 ObjectLockedByBucketPolicy): neither replace nor delete;
// the second check finds the first one's object and still passes.
func TestProbeLockedBucket(t *testing.T) {
	h := newHost(t)
	h.deny("lock")
	if _, err := h.set(); err != nil {
		t.Fatalf("set: %v", err)
	}
	for i := 0; i < 2; i++ {
		o, err := h.test()
		if err != nil || !strings.Contains(o, "step=overwrite ok refused") || !strings.Contains(o, "step=delete ok refused") {
			t.Fatalf("test %d: %v\n%s", i, err, o)
		}
	}
	if l := h.probeObjects(); len(l) != 1 {
		t.Errorf("test objects: %v", l)
	}
}

// A bucket that keeps versions: nothing is deleted (it would only add versions), and the
// delete row says what was not tested.
func TestProbeVersionedBucket(t *testing.T) {
	h := newHost(t)
	if _, err := h.set(); err != nil {
		t.Fatal(err)
	}
	h.deny("versions")
	h.f.mu.Lock()
	h.f.requests = nil
	h.f.mu.Unlock()
	o, err := h.test()
	if err != nil || !strings.Contains(o, "step=overwrite ok kept") || !strings.Contains(o, "step=delete warn "+textVersions) {
		t.Fatalf("%v\n%s", err, o)
	}
	h.f.mu.Lock()
	defer h.f.mu.Unlock()
	puts := 0
	for _, r := range h.f.requests {
		if strings.HasPrefix(r, "DELETE ") {
			t.Errorf("a delete in a bucket with versions: %s", r)
		}
		if strings.HasPrefix(r, "PUT ") {
			puts++
		}
	}
	if puts != 1 {
		t.Errorf("%d writes, want 1 (each one is a version that stays)", puts)
	}
}

// Another failure of the delete (not a refusal) still fails the test.
func TestProbeDeleteError(t *testing.T) {
	h := newHost(t)
	if _, err := h.set(); err != nil {
		t.Fatal(err)
	}
	h.f.fault = func(w http.ResponseWriter, r *http.Request, n int) bool {
		if r.Method == "DELETE" {
			s3err(w, 400, "MalformedThing")
			return true
		}
		return false
	}
	if o, err := h.test(); err == nil || !strings.Contains(o, "step=delete fail") {
		t.Fatalf("%v\n%s", err, o)
	}
}

func TestRefused(t *testing.T) {
	for _, tc := range []struct {
		st   int
		code string
		want bool
	}{
		{403, "AccessDenied", true}, {409, "ObjectLockedByBucketPolicy", true}, {405, "MethodNotAllowed", true},
		{403, "SignatureDoesNotMatch", false}, {403, "InvalidAccessKeyId", false}, {404, "NoSuchBucket", false},
		{409, "OperationAborted", false}, {500, "InternalError", false},
	} {
		if got := refused(&S3Error{Status: tc.st, Code: tc.code}); got != tc.want {
			t.Errorf("%d %s: %v", tc.st, tc.code, got)
		}
	}
	if refused(context.DeadlineExceeded) {
		t.Error("a timeout is no refusal")
	}
}

// Retention with a key that may not delete: nothing is deleted, nothing fails, uploads go on,
// and sync, status and doctor say that the bucket's lifecycle rule must do it; with the
// permission back, the next sync prunes and the message goes.
func TestRetentionWithKeyThatCannotDelete(t *testing.T) {
	h := newHost(t)
	m, _ := h.set("keep_daily=2", "keep_weekly=0", "keep_min=1")
	h.deny("delete")
	for i := 4; i >= 0; i-- {
		id := idAt(time.Now().Add(-time.Duration(i)*24*time.Hour), "daily")
		h.backup("shop", id, map[string]string{"data.tar.gz": "d"})
		if err := h.push("shop", id); err != nil {
			t.Fatalf("push with a key that may not delete: %v", err)
		}
	}
	count := func() int {
		n := 0
		for _, k := range h.f.keys() {
			if strings.HasPrefix(k, "tando/"+m["host_id"]+"/shop/") && strings.HasSuffix(k, "-daily.rbk") {
				n++
			}
		}
		return n
	}
	sync := func() (string, error) {
		return h.do(func(w *out.Writer) error { return h.o.Sync(context.Background(), w, false) })
	}
	o, err := sync()
	if err != nil || !strings.Contains(o, "deleted=0") || !strings.Contains(o, "retention=skipped: "+textPruneRefused) {
		t.Fatalf("sync: %v\n%s", err, o)
	}
	if count() != 5 {
		t.Fatalf("%d backups in the bucket, want all 5", count())
	}
	if h.o.loadHostState()["creds"] != "ok" {
		t.Errorf("a refused delete counted against the credentials: %v", h.o.loadHostState())
	}
	doc, _ := h.do(func(w *out.Writer) error { return h.o.Doctor(context.Background(), w) })
	if !strings.Contains(doc, "check\tok\toffsite retention\tdeletes refused: left to a bucket lifecycle rule\n") {
		t.Errorf("doctor: %s", doc)
	}
	st, _ := h.do(func(w *out.Writer) error { return h.o.Status(context.Background(), w) })
	if !strings.Contains(st, "prune_refused=1") {
		t.Errorf("status: %s", st)
	}
	h.deny("")
	o, _ = sync()
	if !strings.Contains(o, "deleted=3") || strings.Contains(o, "retention=") || count() != 2 {
		t.Fatalf("sync with the permission back: %s (%d left)", o, count())
	}
	doc, _ = h.do(func(w *out.Writer) error { return h.o.Doctor(context.Background(), w) })
	if strings.Contains(doc, "offsite retention") {
		t.Errorf("doctor still says it: %s", doc)
	}
}
