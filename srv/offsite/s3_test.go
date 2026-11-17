package offsite

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func noSleep(ctx context.Context, d time.Duration) error { return ctx.Err() }

func testClient(t testing.TB, f *fakeS3) *s3Client {
	c := f.conf()
	o := Offsite{HTTP: f.srv.Client(), Sleep: noSleep, Tries: 4}
	o.Env.Now = time.Now
	cli, err := o.client(c)
	if err != nil {
		t.Fatal(err)
	}
	return cli
}

func TestUploadSingleAndMultipart(t *testing.T) {
	f := newFakeS3(t)
	cli := testClient(t, f)
	ctx := context.Background()
	for _, tc := range []struct {
		n    int
		part int64
	}{{0, 0}, {1000, 0}, {3<<20 + 5, 1 << 20}, {2 << 20, 1 << 20}} {
		data := make([]byte, tc.n)
		rand.Read(data)
		var started string
		err := cli.upload(ctx, "tando/k", bytes.NewReader(data), int64(tc.n), uploadHooks{partSize: tc.part, started: func(id string) error { started = id; return nil }})
		if err != nil {
			t.Fatalf("n=%d: %v", tc.n, err)
		}
		if !bytes.Equal(f.get("tando/k"), data) {
			t.Fatalf("n=%d: stored bytes differ", tc.n)
		}
		if (tc.part > 0) != (started != "") {
			t.Errorf("n=%d: multipart %v, started %q", tc.n, tc.part > 0, started)
		}
	}
	if f.sigFails != 0 {
		t.Fatalf("%d signature failures", f.sigFails)
	}
	if len(f.uploads) != 0 {
		t.Fatal("unfinished uploads left")
	}
	if partSizeFor(50<<30) != 8<<20 || partSizeFor(100<<30) != 16<<20 || partSizeFor(200<<30) != 0 {
		t.Fatal("part sizes")
	}
}

// 5xx, 429 and a dropped connection are retried; a 4xx is not.
func TestRetries(t *testing.T) {
	f := newFakeS3(t)
	cli := testClient(t, f)
	fails := 0
	f.fault = func(w http.ResponseWriter, r *http.Request, n int) bool {
		if r.Method == "PUT" && fails < 3 {
			fails++
			switch fails {
			case 1:
				s3err(w, 500, "InternalError")
			case 2:
				s3err(w, 429, "SlowDown")
			case 3:
				hj, _ := w.(http.Hijacker)
				c, _, _ := hj.Hijack()
				c.Close()
			}
			return true
		}
		return false
	}
	if err := cli.put(context.Background(), "tando/x", []byte("hello"), ""); err != nil {
		t.Fatal(err)
	}
	if string(f.get("tando/x")) != "hello" {
		t.Fatal("not stored")
	}
	f.fault = func(w http.ResponseWriter, r *http.Request, n int) bool { s3err(w, 503, "SlowDown"); return true }
	err := cli.put(context.Background(), "tando/y", []byte("x"), "")
	var se *S3Error
	if !errors.As(err, &se) || se.Code != "SlowDown" {
		t.Fatalf("gave up with %v", err)
	}
	n := 0
	f.fault = func(w http.ResponseWriter, r *http.Request, _ int) bool {
		n++
		s3err(w, 403, "AccessDenied")
		return true
	}
	if err := cli.put(context.Background(), "tando/y", []byte("x"), ""); err == nil || n != 1 || !strings.Contains(err.Error(), "permission") {
		t.Fatalf("403 retried %d times: %v", n, err)
	}
}

// A part whose ETag is not the MD5 of what was sent fails the upload, and the upload is aborted
// (no parts left behind, nothing under the key).
func TestWrongETagAborts(t *testing.T) {
	f := newFakeS3(t)
	cli := testClient(t, f)
	f.fault = func(w http.ResponseWriter, r *http.Request, n int) bool {
		if r.Method == "PUT" && r.URL.Query().Get("partNumber") == "2" {
			io.Copy(io.Discard, r.Body)
			w.Header().Set("ETag", `"00000000000000000000000000000000"`)
			return true
		}
		return false
	}
	data := make([]byte, 3<<20)
	err := cli.upload(context.Background(), "tando/k", bytes.NewReader(data), int64(len(data)), uploadHooks{partSize: 1 << 20})
	if err == nil || !strings.Contains(err.Error(), "different bytes") {
		t.Fatalf("err %v", err)
	}
	if len(f.uploads) != 0 || f.get("tando/k") != nil {
		t.Fatal("upload not aborted, or an object is visible")
	}
}

// Complete can answer 200 with an <Error> document: that is a failure.
func TestCompleteErrorIn200(t *testing.T) {
	f := newFakeS3(t)
	cli := testClient(t, f)
	f.fault = func(w http.ResponseWriter, r *http.Request, n int) bool {
		if r.Method == "POST" && r.URL.Query().Get("uploadId") != "" {
			io.WriteString(w, `<?xml version="1.0"?><Error><Code>InternalError</Code></Error>`)
			return true
		}
		return false
	}
	data := make([]byte, 2<<20+1)
	if err := cli.upload(context.Background(), "tando/k", bytes.NewReader(data), int64(len(data)), uploadHooks{partSize: 1 << 20}); err == nil {
		t.Fatal("accepted")
	}
}

// A download cut off mid-way resumes with a Range, and only from the same version (If-Match).
func TestDownloadResume(t *testing.T) {
	f := newFakeS3(t)
	cli := testClient(t, f)
	data := make([]byte, 1<<20)
	rand.Read(data)
	cli.put(context.Background(), "tando/obj", data, "")
	cuts, ranged := 0, 0
	f.fault = func(w http.ResponseWriter, r *http.Request, n int) bool {
		if r.Method != "GET" {
			return false
		}
		if r.Header.Get("Range") != "" {
			ranged++
			if r.Header.Get("If-Match") == "" {
				t.Error("resume without If-Match")
			}
			return false
		}
		if cuts == 0 {
			cuts++
			// a truncated body: the whole length promised, a part sent, the connection closed
			w.Header().Set("Content-Length", "1048576")
			w.Header().Set("ETag", `"`+f.objs["tando/obj"].etag+`"`)
			w.WriteHeader(200)
			w.Write(data[:300000])
			return true
		}
		return false
	}
	rr, err := cli.openResumable(context.Background(), "tando/obj", 5)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(rr)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("resume: %v, %d bytes", err, len(got))
	}
	if cuts != 1 || ranged != 1 {
		t.Fatalf("cut %d times, resumed %d times", cuts, ranged)
	}
}

// A multi-gigabyte upload through the real producer keeps the heap small (one part buffered).
func TestUploadBoundedMemory(t *testing.T) {
	if testing.Short() {
		t.Skip("short")
	}
	f := newFakeS3(t)
	f.discard = true
	cli := testClient(t, f)
	const n = 1 << 30
	stopWatch := watchHeap()
	err := cli.upload(context.Background(), "tando/big", &genReader{n: n}, n, uploadHooks{})
	peak := stopWatch()
	if err != nil {
		t.Fatal(err)
	}
	if f.objs["tando/big"].size != n {
		t.Fatal("size")
	}
	// the fake server holds a part too (it reads the body whole), and the transport its buffers
	if peak > 96<<20 {
		t.Fatalf("heap peaked at %d MB", peak>>20)
	}
	t.Logf("1 GiB upload, heap peak %d MB", peak>>20)
}

func TestParseListRejects(t *testing.T) {
	ok := `<ListBucketResult><Contents><Key>p/a</Key><Size>3</Size></Contents><IsTruncated>false</IsTruncated></ListBucketResult>`
	if _, err := parseList([]byte(ok), "p/"); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		`<ListBucketResult><Contents><Key>q/a</Key><Size>3</Size></Contents></ListBucketResult>`,
		`<ListBucketResult><Contents><Key>p/a</Key><Size>-1</Size></Contents></ListBucketResult>`,
		`<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>`,
		`<Error><Code>X</Code></Error>`,
		`<ListBucketResult><CommonPrefixes><Prefix>x/</Prefix></CommonPrefixes></ListBucketResult>`,
		`not xml`,
	} {
		if _, err := parseList([]byte(bad), "p/"); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}

func TestEndpointRules(t *testing.T) {
	for _, s := range []string{"https://x.r2.cloudflarestorage.com", "http://127.0.0.1:9000", "https://s3.eu-central-1.amazonaws.com/"} {
		if _, err := checkEndpoint(s); err != nil {
			t.Errorf("%s: %v", s, err)
		}
	}
	for _, s := range []string{"http://example.com", "ftp://x", "https://u:p@x", "https://x/path", "https://x?q=1", ""} {
		if _, err := checkEndpoint(s); err == nil {
			t.Errorf("%s accepted", s)
		}
	}
}

func TestConfValidation(t *testing.T) {
	base := func() map[string]string {
		return map[string]string{"account_id": "0123456789abcdef0123456789abcdef", "bucket": "my-backups",
			"access_key_id": "0123456789abcdef0123456789abcdef", "secret_access_key": "s3cr3t-0123456789"}
	}
	c, err := confFrom(base())
	if err != nil || c.Endpoint != "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com" ||
		c.Region != "auto" || c.Prefix != "tando" || !c.Encrypt || c.Keep != DefaultKeep || c.AlertHours != 6 {
		t.Fatalf("%+v %v", c, err)
	}
	for _, bad := range []map[string]string{
		{"account_id": "nothex"}, {"bucket": "A"}, {"bucket": "a..b"}, {"prefix": "../x"}, {"prefix": "/x"},
		{"secret_access_key": "has space here"}, {"encrypt": "maybe"}, {"keep_min": "0"}, {"keep_daily": "-1"},
		{"alert_hours": "0"}, {"region": "Auto Region"}, {"access_key_id": "a"},
	} {
		m := base()
		for k, v := range bad {
			m[k] = v
		}
		if _, err := confFrom(m); err == nil {
			t.Errorf("%v accepted", bad)
		} else if strings.Contains(err.Error(), "s3cr3t") {
			t.Errorf("error shows the secret: %v", err)
		}
	}
	m := base()
	m["encrypt"] = "off"
	m["keep_daily"] = "30"
	m["keep_monthly"] = "12"
	if c, err := confFrom(m); err != nil || c.Encrypt || c.Keep.Daily != 30 || c.Keep.Monthly != 12 {
		t.Fatal(c, err)
	}
	if _, err := readSettings(strings.NewReader("bucket=x\nnope=1\n")); err == nil {
		t.Fatal("unknown setting accepted")
	}
}
