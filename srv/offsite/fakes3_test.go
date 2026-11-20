package offsite

import (
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeS3 is an in-process S3 for the tests: path-style, one bucket, objects in memory (or only
// their sizes and hashes, for big uploads), multipart, ListObjectsV2 with paging and delimiters,
// ranges and If-Match. Every request's SigV4 signature is checked by its own code below, written
// from the specification separately from sigv4.go (another reading of the same rules), and
// so is the payload hash and Content-MD5. fault lets a test answer a request itself.
type fakeS3 struct {
	t       testing.TB
	srv     *httptest.Server
	bucket  string
	access  string
	secret  string
	region  string
	discard bool // keep only sizes and MD5s (multi-GB uploads)
	skew    time.Duration

	mu       sync.Mutex
	objs     map[string]*fakeObj
	uploads  map[string]*fakeUpload
	nextID   int
	requests []string // "METHOD key?query"
	fault    func(w http.ResponseWriter, r *http.Request, n int) bool
	n        int
	sigFails int
	// deny: what the key may not do to an object. "delete": DeleteObject is refused (a key
	// without that permission); "lock": deleting or replacing an existing object is refused (a
	// bucket lock rule); "versions": the bucket keeps versions (a PUT answers with a version id).
	deny string
}

type fakeObj struct {
	data []byte
	size int64
	etag string
	mod  time.Time
}

type fakeUpload struct {
	key   string
	parts map[int]*fakeObj
}

func newFakeS3(t testing.TB) *fakeS3 {
	f := &fakeS3{t: t, bucket: "bkt", access: "AKIDTESTKEY1", secret: "secret/TEST+key0123456789", region: "auto",
		objs: map[string]*fakeObj{}, uploads: map[string]*fakeUpload{}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeS3) conf() Conf {
	c, err := confFrom(map[string]string{"endpoint": f.srv.URL, "bucket": f.bucket, "access_key_id": f.access,
		"secret_access_key": f.secret, "prefix": "tando"})
	if err != nil {
		f.t.Fatal(err)
	}
	return c
}

func (f *fakeS3) keys() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var r []string
	for k := range f.objs {
		r = append(r, k)
	}
	sort.Strings(r)
	return r
}

func (f *fakeS3) get(key string) []byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	if o := f.objs[key]; o != nil {
		return o.data
	}
	return nil
}

func s3err(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/xml")
	w.WriteHeader(status)
	fmt.Fprintf(w, `<?xml version="1.0" encoding="UTF-8"?><Error><Code>%s</Code><Message>m</Message></Error>`, code)
}

// ---- an independent SigV4 check --------------------------------------------------------------

func tEnc(s string, slash bool) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte("-._~", c) >= 0 || (c == '/' && !slash) {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func tHMAC(k []byte, s string) []byte {
	m := hmac.New(sha256.New, k)
	m.Write([]byte(s))
	return m.Sum(nil)
}

func (f *fakeS3) checkSig(r *http.Request, body []byte) string {
	auth := r.Header.Get("Authorization")
	const pre = "AWS4-HMAC-SHA256 Credential="
	if !strings.HasPrefix(auth, pre) {
		return "AccessDenied"
	}
	parts := strings.Split(strings.TrimPrefix(auth, pre), ", ")
	if len(parts) != 3 || !strings.HasPrefix(parts[1], "SignedHeaders=") || !strings.HasPrefix(parts[2], "Signature=") {
		return "AccessDenied"
	}
	cred := strings.Split(parts[0], "/")
	if len(cred) != 5 || cred[0] != f.access {
		return "InvalidAccessKeyId"
	}
	amz := r.Header.Get("X-Amz-Date")
	tm, err := time.Parse("20060102T150405Z", amz)
	if err != nil || cred[1] != amz[:8] || cred[2] != f.region || cred[3] != "s3" || cred[4] != "aws4_request" {
		return "AccessDenied"
	}
	now := time.Now().Add(f.skew)
	if d := now.Sub(tm); d > 15*time.Minute || d < -15*time.Minute {
		return "RequestTimeTooSkewed"
	}
	ph := r.Header.Get("X-Amz-Content-Sha256")
	sum := sha256.Sum256(body)
	if ph != hex.EncodeToString(sum[:]) {
		return "XAmzContentSHA256Mismatch"
	}
	signed := strings.Split(strings.TrimPrefix(parts[1], "SignedHeaders="), ";")
	var ch strings.Builder
	for _, h := range signed {
		v := r.Header.Get(h)
		if h == "host" {
			v = r.Host
		}
		ch.WriteString(h + ":" + strings.Join(strings.Fields(v), " ") + "\n")
	}
	var qs []string
	for k, vs := range r.URL.Query() {
		for _, v := range vs {
			qs = append(qs, tEnc(k, true)+"="+tEnc(v, true))
		}
	}
	sort.Strings(qs)
	creq := r.Method + "\n" + tEnc(r.URL.Path, false) + "\n" + strings.Join(qs, "&") + "\n" + ch.String() + "\n" +
		strings.Join(signed, ";") + "\n" + ph
	h := sha256.Sum256([]byte(creq))
	sts := "AWS4-HMAC-SHA256\n" + amz + "\n" + strings.Join(cred[1:], "/") + "\n" + hex.EncodeToString(h[:])
	k := tHMAC(tHMAC(tHMAC(tHMAC([]byte("AWS4"+f.secret), cred[1]), cred[2]), cred[3]), cred[4])
	if hex.EncodeToString(tHMAC(k, sts)) != strings.TrimPrefix(parts[2], "Signature=") {
		return "SignatureDoesNotMatch"
	}
	if cm := r.Header.Get("Content-Md5"); cm != "" {
		m := md5.Sum(body)
		if cm != base64.StdEncoding.EncodeToString(m[:]) {
			return "BadDigest"
		}
	}
	return ""
}

// ---- the server ------------------------------------------------------------------------------

func (f *fakeS3) serve(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Date", time.Now().Add(f.skew).UTC().Format(http.TimeFormat))
	f.mu.Lock()
	f.n++
	n := f.n
	fault := f.fault
	f.mu.Unlock()
	if fault != nil && fault(w, r, n) {
		return
	}
	body, _ := io.ReadAll(r.Body)
	if code := f.checkSig(r, body); code != "" {
		f.mu.Lock()
		f.sigFails++
		f.mu.Unlock()
		st := 403
		if code == "XAmzContentSHA256Mismatch" || code == "BadDigest" {
			st = 400
		}
		s3err(w, st, code)
		return
	}
	p := strings.TrimPrefix(r.URL.Path, "/")
	bucket, key, _ := strings.Cut(p, "/")
	if bucket != f.bucket {
		s3err(w, 404, "NoSuchBucket")
		return
	}
	q := r.URL.Query()
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests = append(f.requests, r.Method+" "+key+"?"+r.URL.RawQuery)
	switch {
	case r.Method == "GET" && key == "" && q.Get("list-type") == "2":
		f.list(w, q)
	case r.Method == "PUT" && q.Get("uploadId") != "":
		u := f.uploads[q.Get("uploadId")]
		if u == nil {
			s3err(w, 404, "NoSuchUpload")
			return
		}
		pn, _ := strconv.Atoi(q.Get("partNumber"))
		o := f.store(body)
		u.parts[pn] = o
		w.Header().Set("ETag", `"`+o.etag+`"`)
	case r.Method == "PUT":
		if f.deny == "lock" && f.objs[key] != nil {
			s3err(w, 409, "ObjectLockedByBucketPolicy")
			return
		}
		o := f.store(body)
		f.objs[key] = o
		w.Header().Set("ETag", `"`+o.etag+`"`)
		if f.deny == "versions" {
			f.nextID++
			w.Header().Set("X-Amz-Version-Id", "v"+strconv.Itoa(f.nextID))
		}
	case r.Method == "POST" && q.Has("uploads"):
		f.nextID++
		id := "up" + strconv.Itoa(f.nextID)
		f.uploads[id] = &fakeUpload{key: key, parts: map[int]*fakeObj{}}
		fmt.Fprintf(w, `<?xml version="1.0"?><InitiateMultipartUploadResult><Bucket>bkt</Bucket><Key>%s</Key><UploadId>%s</UploadId></InitiateMultipartUploadResult>`, key, id)
	case r.Method == "POST" && q.Get("uploadId") != "":
		u := f.uploads[q.Get("uploadId")]
		if u == nil {
			s3err(w, 404, "NoSuchUpload")
			return
		}
		var x struct {
			Parts []struct {
				N    int    `xml:"PartNumber"`
				ETag string `xml:"ETag"`
			} `xml:"Part"`
		}
		if xml.Unmarshal(body, &x) != nil {
			s3err(w, 400, "MalformedXML")
			return
		}
		all := &fakeObj{mod: time.Now()}
		var sums []byte
		for i, pt := range x.Parts {
			o := u.parts[pt.N]
			if o == nil || pt.N != i+1 || strings.Trim(pt.ETag, `"`) != o.etag {
				s3err(w, 400, "InvalidPart")
				return
			}
			if !f.discard {
				all.data = append(all.data, o.data...)
			}
			all.size += o.size
			m, _ := hex.DecodeString(o.etag)
			sums = append(sums, m...)
		}
		m := md5.Sum(sums)
		all.etag = hex.EncodeToString(m[:]) + "-" + strconv.Itoa(len(x.Parts))
		f.objs[u.key] = all
		delete(f.uploads, q.Get("uploadId"))
		fmt.Fprintf(w, `<?xml version="1.0"?><CompleteMultipartUploadResult><Key>%s</Key><ETag>"%s"</ETag></CompleteMultipartUploadResult>`, u.key, all.etag)
	case r.Method == "DELETE" && q.Get("uploadId") != "":
		delete(f.uploads, q.Get("uploadId"))
		w.WriteHeader(204)
	case r.Method == "DELETE":
		if f.deny == "delete" {
			s3err(w, 403, "AccessDenied")
			return
		}
		if f.deny == "lock" && f.objs[key] != nil {
			s3err(w, 409, "ObjectLockedByBucketPolicy")
			return
		}
		delete(f.objs, key)
		w.WriteHeader(204)
	case r.Method == "HEAD" || r.Method == "GET":
		o := f.objs[key]
		if o == nil {
			s3err(w, 404, "NoSuchKey")
			return
		}
		if im := r.Header.Get("If-Match"); im != "" && strings.Trim(im, `"`) != o.etag {
			s3err(w, 412, "PreconditionFailed")
			return
		}
		w.Header().Set("ETag", `"`+o.etag+`"`)
		w.Header().Set("Last-Modified", o.mod.UTC().Format(http.TimeFormat))
		data := o.data
		var off int64
		if rg := r.Header.Get("Range"); rg != "" {
			fmt.Sscanf(rg, "bytes=%d-", &off)
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", off, o.size-1, o.size))
			w.Header().Set("Content-Length", strconv.FormatInt(o.size-off, 10))
			w.WriteHeader(206)
		} else {
			w.Header().Set("Content-Length", strconv.FormatInt(o.size, 10))
		}
		if r.Method == "GET" {
			w.Write(data[off:])
		}
	default:
		s3err(w, 400, "NotImplemented")
	}
}

func (f *fakeS3) store(body []byte) *fakeObj {
	m := md5.Sum(body)
	o := &fakeObj{size: int64(len(body)), etag: hex.EncodeToString(m[:]), mod: time.Now()}
	if !f.discard {
		o.data = body
	}
	return o
}

func (f *fakeS3) list(w http.ResponseWriter, q url.Values) {
	prefix, delim := q.Get("prefix"), q.Get("delimiter")
	max, _ := strconv.Atoi(q.Get("max-keys"))
	if max <= 0 || max > 1000 {
		max = 1000
	}
	var keys []string
	for k := range f.objs {
		if strings.HasPrefix(k, prefix) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	type ent struct {
		key    string
		prefix bool
	}
	var ents []ent
	seen := map[string]bool{}
	for _, k := range keys {
		if delim != "" {
			if i := strings.Index(k[len(prefix):], delim); i >= 0 {
				cp := k[:len(prefix)+i+1]
				if !seen[cp] {
					seen[cp] = true
					ents = append(ents, ent{cp, true})
				}
				continue
			}
		}
		ents = append(ents, ent{k, false})
	}
	start := 0
	if tok := q.Get("continuation-token"); tok != "" {
		start, _ = strconv.Atoi(tok)
	}
	end := min(start+max, len(ents))
	var b strings.Builder
	b.WriteString(`<?xml version="1.0"?><ListBucketResult><Name>bkt</Name>`)
	for _, e := range ents[start:end] {
		if e.prefix {
			fmt.Fprintf(&b, "<CommonPrefixes><Prefix>%s</Prefix></CommonPrefixes>", e.key)
		} else {
			o := f.objs[e.key]
			fmt.Fprintf(&b, `<Contents><Key>%s</Key><Size>%d</Size><ETag>"%s"</ETag><LastModified>%s</LastModified></Contents>`,
				e.key, o.size, o.etag, o.mod.UTC().Format(time.RFC3339Nano))
		}
	}
	if end < len(ents) {
		fmt.Fprintf(&b, "<IsTruncated>true</IsTruncated><NextContinuationToken>%d</NextContinuationToken>", end)
	} else {
		b.WriteString("<IsTruncated>false</IsTruncated>")
	}
	b.WriteString("</ListBucketResult>")
	io.WriteString(w, b.String())
}
