// fakes3: a small S3-compatible server for test/e2e-offsite.sh, standard library only. It is the
// fallback for MinIO (its image could not be pulled where the suite was written): path-style, one
// bucket, objects in memory, multipart, ListObjectsV2 with paging and delimiters, ranges and
// If-Match, every request's SigV4 signature, payload hash and Content-MD5 checked (the same
// independent check as srv/offsite's unit tests). TLS with a certificate it makes at start for
// the names and addresses given; the CA certificate is written to -ca so test servers can trust it.
//
//	fakes3 -addr :9000 -bucket b -access K -secret S -names s3.test,10.0.0.5 -ca /out/ca.pem
//
// /_ctl/ (no signature; tests only): fail=writes|off, list (key size per line), get?key=, count.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"encoding/xml"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

func main() {
	addr := flag.String("addr", ":9000", "listen address")
	f := &fakeS3{objs: map[string]*fakeObj{}, uploads: map[string]*fakeUpload{}, region: "auto"}
	flag.StringVar(&f.bucket, "bucket", "tando-test", "bucket")
	flag.StringVar(&f.access, "access", "", "access key id")
	flag.StringVar(&f.secret, "secret", "", "secret access key")
	names := flag.String("names", "localhost", "certificate names and addresses, comma-separated")
	caOut := flag.String("ca", "", "write the CA certificate here")
	plain := flag.Bool("http", false, "plain http (no TLS)")
	flag.Parse()
	srv := &http.Server{Addr: *addr, Handler: http.HandlerFunc(f.serve)}
	if *plain {
		log.Fatal(srv.ListenAndServe())
	}
	cert, caPEM := makeCert(strings.Split(*names, ","))
	if *caOut != "" {
		if err := os.WriteFile(*caOut, caPEM, 0o644); err != nil {
			log.Fatal(err)
		}
	}
	srv.TLSConfig = &tls.Config{Certificates: []tls.Certificate{cert}}
	log.Fatal(srv.ListenAndServeTLS("", ""))
}

func makeCert(names []string) (tls.Certificate, []byte) {
	caKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "tando test CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(30 * 24 * time.Hour), IsCA: true,
		KeyUsage: x509.KeyUsageCertSign, BasicConstraintsValid: true}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey)
	if err != nil {
		log.Fatal(err)
	}
	ca, _ = x509.ParseCertificate(caDER)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	leaf := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: names[0]},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(30 * 24 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	for _, n := range names {
		if ip := net.ParseIP(n); ip != nil {
			leaf.IPAddresses = append(leaf.IPAddresses, ip)
		} else if n != "" {
			leaf.DNSNames = append(leaf.DNSNames, n)
		}
	}
	der, err := x509.CreateCertificate(rand.Reader, leaf, ca, &key.PublicKey, caKey)
	if err != nil {
		log.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der, caDER}, PrivateKey: key},
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})
}

func s3err(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/xml")
	w.WriteHeader(status)
	fmt.Fprintf(w, `<?xml version="1.0" encoding="UTF-8"?><Error><Code>%s</Code><Message>m</Message></Error>`, code)
}

func (f *fakeS3) ctl(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch strings.TrimPrefix(r.URL.Path, "/_ctl/") {
	case "fail":
		f.failMode = r.URL.Query().Get("mode")
		if f.failMode == "off" {
			f.failMode = ""
		}
	case "list":
		var ks []string
		for k := range f.objs {
			ks = append(ks, k)
		}
		sort.Strings(ks)
		for _, k := range ks {
			fmt.Fprintf(w, "%s %d\n", k, f.objs[k].size)
		}
	case "uploads":
		for id, u := range f.uploads {
			fmt.Fprintf(w, "%s %s %d\n", id, u.key, len(u.parts))
		}
	case "get":
		if o := f.objs[r.URL.Query().Get("key")]; o != nil {
			w.Write(o.data)
		} else {
			w.WriteHeader(404)
		}
	case "secret": // credentials revoked (or given back)
		f.secret = r.URL.Query().Get("value")
	case "delay": // each upload part waits this long (a slow link, for the kill test)
		f.delay, _ = time.ParseDuration(r.URL.Query().Get("d"))
	case "requests":
		fmt.Fprintf(w, "%d\n", f.n)
	default:
		w.WriteHeader(404)
	}
}

type fakeS3 struct {
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
	failMode string   // "": normal; "writes": every write answers 500
	delay    time.Duration
	n        int
	sigFails int
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
	fault := f.failMode
	f.mu.Unlock()
	if strings.HasPrefix(r.URL.Path, "/_ctl/") {
		f.ctl(w, r)
		return
	}
	if fault != "" && !(r.Method == "GET" || r.Method == "HEAD") {
		io.Copy(io.Discard, r.Body)
		s3err(w, 500, "InternalError")
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
		if f.delay > 0 {
			f.mu.Unlock()
			time.Sleep(f.delay)
			f.mu.Lock()
		}
		pn, _ := strconv.Atoi(q.Get("partNumber"))
		o := f.store(body)
		u.parts[pn] = o
		w.Header().Set("ETag", `"`+o.etag+`"`)
	case r.Method == "PUT":
		o := f.store(body)
		f.objs[key] = o
		w.Header().Set("ETag", `"`+o.etag+`"`)
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
