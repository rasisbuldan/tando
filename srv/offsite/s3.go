package offsite

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// The S3 API subset tando uses, by hand over net/http (no SDK: the standard library only):
// PutObject, the multipart upload (Create, UploadPart, Complete, Abort), GetObject (streamed,
// with a Range to resume), HeadObject, ListObjectsV2 (paged), DeleteObject. Path-style
// addressing (https://<endpoint>/<bucket>/<key>), which R2, B2, MinIO and AWS all accept.
//
// The payload is signed (x-amz-content-sha256 is the body's SHA-256, not UNSIGNED-PAYLOAD):
// tando holds every body in memory anyway (a part is at most 16 MiB), so the hash costs one pass,
// and the signature then covers the bytes as well as the request: the store refuses a body that
// changed on the way (XAmzContentSHA256Mismatch) even where TLS ends before it (a proxy, a CDN
// in front of MinIO). R2 accepts both forms over HTTPS. Content-MD5 is sent as well: every
// S3-compatible store checks it, and its ETag of a single-part object is that MD5.

const (
	maxErrBody  = 64 << 10 // an error document
	maxListBody = 8 << 20  // one ListObjectsV2 page (1000 keys)
	maxSmallXML = 1 << 20  // Initiate/Complete answers
	maxKeyLen   = 1024     // S3's limit of a key
	userAgent   = "tando-offsite"
)

// s3Client talks to one bucket.
type s3Client struct {
	base   *url.URL // scheme://host[:port], nothing else
	bucket string
	sig    signer
	hc     *http.Client
	now    func() time.Time
	sleep  func(context.Context, time.Duration) error
	tries  int // attempts per request (network errors, 5xx, 429)
	// skew is the last difference seen between the store's Date and our clock (positive: the
	// store is ahead); set by every answer, read for the clock-skew message
	skew time.Duration
}

// S3Error is a failed request: the store's answer, or what went wrong on the way.
type S3Error struct {
	Op      string // put, get, list, ...
	Key     string
	Status  int    // HTTP status (0: no answer)
	Code    string // the store's code (NoSuchBucket, AccessDenied, ...)
	Message string
	Skew    time.Duration
	Err     error // the network error, when there was no answer
}

func (e *S3Error) Error() string {
	what := e.Op
	if e.Key != "" {
		what += " " + e.Key
	}
	switch {
	case e.Status == 0 && e.Err != nil:
		return what + ": " + netMessage(e.Err)
	case e.Code != "":
		return what + ": " + explainCode(e)
	}
	return what + ": HTTP " + strconv.Itoa(e.Status)
}

func (e *S3Error) Unwrap() error { return e.Err }

// explainCode turns the store's code into what the admin can do about it; the store's own
// message is not repeated (it can echo a key id, which is not secret but need not be in logs).
func explainCode(e *S3Error) string {
	skew := ""
	if e.Skew > 5*time.Minute || e.Skew < -5*time.Minute {
		skew = fmt.Sprintf(" (this server's clock is %s off the storage's: fix it with NTP, e.g. timedatectl set-ntp true)", absDur(e.Skew).Round(time.Second))
	}
	switch e.Code {
	case "RequestTimeTooSkewed":
		return "the server's clock differs from the storage's by more than 15 minutes, which breaks request signing" + skew
	case "InvalidAccessKeyId":
		return "the storage does not know this access key id (wrong key, or the token was deleted)" + skew
	case "SignatureDoesNotMatch":
		return "the secret access key does not match the access key id (wrong secret?)" + skew
	case "NoSuchBucket":
		return "no such bucket (check the name; R2: the bucket must be in this account)"
	case "AccessDenied", "Forbidden":
		return "access denied: the token has no permission for this (R2: Object Read & Write on this bucket)" + skew
	case "NoSuchKey":
		return "no such object"
	case "XAmzContentSHA256Mismatch", "BadDigest", "InvalidDigest":
		return "the storage received different bytes than were sent (" + e.Code + ")"
	case "EntityTooLarge", "EntityTooSmall", "InvalidPart", "InvalidPartOrder", "NoSuchUpload":
		return "the multipart upload was refused (" + e.Code + ")"
	case "SlowDown", "ServiceUnavailable", "InternalError":
		return "the storage is busy or failing (" + e.Code + "); retried and gave up"
	case "redirect":
		return "the endpoint answered with a redirect (" + strconv.Itoa(e.Status) + "): wrong endpoint or region? tando does not follow redirects"
	}
	return e.Code + " (HTTP " + strconv.Itoa(e.Status) + ")"
}

func absDur(d time.Duration) time.Duration {
	if d < 0 {
		return -d
	}
	return d
}

// netMessage: a network error in words, without the URL (Go's *url.Error repeats it)
func netMessage(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		err = ue.Err
	}
	var ce *tls.CertificateVerificationError
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "no answer in time (timeout)"
	case errors.As(err, &ce):
		return "the endpoint's TLS certificate is not trusted: " + err.Error()
	}
	var de *net.DNSError
	if errors.As(err, &de) {
		return "the endpoint's name does not resolve (" + de.Name + ")"
	}
	return err.Error()
}

// newHTTPClient: TLS verified (the system's roots), TLS 1.2 at least, no proxy from the
// environment, no redirects followed (an endpoint that sends us elsewhere would get the
// signed request, and a store never redirects a well-addressed path-style request), bounded
// connect and header waits; the body of a long transfer is bounded by its context.
func newHTTPClient() *http.Client {
	tr := &http.Transport{
		Proxy:                 nil,
		DialContext:           (&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout:   15 * time.Second,
		ResponseHeaderTimeout: 2 * time.Minute,
		IdleConnTimeout:       60 * time.Second,
		MaxIdleConnsPerHost:   4,
		ForceAttemptHTTP2:     true,
	}
	return &http.Client{Transport: tr, CheckRedirect: noRedirect}
}

func noRedirect(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

// encodePath: a path as sent and signed, each byte but "/" URI-encoded (S3 encodes once)
func encodePath(p string) string { return uriEncode(p, false) }

func (c *s3Client) objPath(key string) string {
	if key == "" {
		return "/" + c.bucket
	}
	return "/" + c.bucket + "/" + key
}

type reqSpec struct {
	op, method, key, query string
	hdr                    http.Header
	body                   []byte
	timeout                time.Duration
	stream                 bool // the caller reads the body: no overall timeout, only ctx's
}

// do sends a request, retrying network errors, 5xx and 429 with backoff and jitter. A 2xx/3xx/4xx
// answer is returned as it is (the caller decides); a body is replayed from memory on retry.
func (c *s3Client) do(ctx context.Context, rs reqSpec) (*http.Response, context.CancelFunc, error) {
	tries := c.tries
	if tries < 1 {
		tries = 1
	}
	var last error
	for i := 0; i < tries; i++ {
		if i > 0 {
			if err := c.sleep(ctx, backoff(i)); err != nil {
				return nil, nil, &S3Error{Op: rs.op, Key: rs.key, Err: err}
			}
		}
		resp, cancel, err := c.once(ctx, rs)
		if err != nil {
			last = &S3Error{Op: rs.op, Key: rs.key, Err: err}
			if ctx.Err() != nil {
				return nil, nil, last
			}
			continue
		}
		if resp.StatusCode >= 500 || resp.StatusCode == 429 {
			last = c.errorOf(rs, resp)
			cancel()
			continue
		}
		return resp, cancel, nil
	}
	return nil, nil, last
}

// backoff: 1, 2, 4, 8, 16, 30, 30 s ..., with full jitter between half and all of it
func backoff(try int) time.Duration {
	d := time.Second << min(try-1, 5)
	if d > 30*time.Second {
		d = 30 * time.Second
	}
	var b [8]byte
	rand.Read(b[:])
	half := d / 2
	return half + time.Duration(binary.BigEndian.Uint64(b[:])%uint64(half+1))
}

func (c *s3Client) once(ctx context.Context, rs reqSpec) (*http.Response, context.CancelFunc, error) {
	var cancel context.CancelFunc
	if rs.timeout > 0 && !rs.stream {
		ctx, cancel = context.WithTimeout(ctx, rs.timeout)
	} else {
		ctx, cancel = context.WithCancel(ctx)
	}
	raw := c.objPath(rs.key)
	path := encodePath(raw)
	var body io.Reader
	if rs.body != nil {
		body = bytes.NewReader(rs.body)
	}
	req, err := http.NewRequestWithContext(ctx, rs.method, c.base.String(), body)
	if err != nil {
		cancel()
		return nil, nil, err
	}
	// the path goes out exactly as it was signed (RawPath is used when it encodes Path)
	req.URL = &url.URL{Scheme: c.base.Scheme, Host: c.base.Host, Path: raw, RawPath: path, RawQuery: rs.query}
	req.Host = c.base.Host
	for k, vs := range rs.hdr {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	ph := emptySHA256
	if len(rs.body) > 0 {
		h := sha256.Sum256(rs.body)
		ph = hex.EncodeToString(h[:])
	}
	req.ContentLength = int64(len(rs.body))
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("X-Amz-Content-Sha256", ph)
	c.sig.sign(req, path, ph, c.now())
	resp, err := c.hc.Do(req)
	if err != nil {
		cancel()
		return nil, nil, err
	}
	if d, err := http.ParseTime(resp.Header.Get("Date")); err == nil {
		c.skew = d.Sub(c.now())
	}
	return resp, cancel, nil
}

// errorOf reads (a bounded part of) an error answer and closes it
func (c *s3Client) errorOf(rs reqSpec, resp *http.Response) *S3Error {
	defer resp.Body.Close()
	e := &S3Error{Op: rs.op, Key: rs.key, Status: resp.StatusCode, Skew: c.skew}
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		e.Code = "redirect"
		return e
	}
	b, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrBody))
	var x struct {
		Code    string `xml:"Code"`
		Message string `xml:"Message"`
	}
	if xml.Unmarshal(b, &x) == nil {
		e.Code, e.Message = cleanCode(x.Code), x.Message
	}
	if e.Code == "" { // HEAD has no body; some stores answer plain text
		switch resp.StatusCode {
		case 404:
			e.Code = "NoSuchKey"
		case 403:
			e.Code = "AccessDenied"
		}
	}
	return e
}

// cleanCode: a store's code is a word; anything else is not shown as one
func cleanCode(s string) string {
	if len(s) > 64 {
		return "?"
	}
	for _, r := range s {
		if !(r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9') {
			return "?"
		}
	}
	return s
}

func bodyMD5(b []byte) (string, string) {
	m := md5.Sum(b)
	return base64.StdEncoding.EncodeToString(m[:]), hex.EncodeToString(m[:])
}

// unquote an ETag ("abc" -> abc; W/ is not used by S3)
func unquote(s string) string { return strings.Trim(strings.TrimSpace(s), `"`) }

func isMD5Hex(s string) bool {
	if len(s) != 32 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !isHex(s[i]) {
			return false
		}
	}
	return true
}

// timeouts of one request carrying n bytes: a minute, plus what n takes at 32 KiB/s
func xferTimeout(n int) time.Duration {
	return time.Minute + time.Duration(n/(32<<10))*time.Second
}

// put stores body under key (a single request: small objects and the manifests).
func (c *s3Client) put(ctx context.Context, key string, body []byte, ctype string) error {
	b64, hx := bodyMD5(body)
	h := http.Header{"Content-Md5": {b64}}
	if ctype != "" {
		h.Set("Content-Type", ctype)
	}
	rs := reqSpec{op: "put", method: "PUT", key: key, hdr: h, body: body, timeout: xferTimeout(len(body))}
	if body == nil {
		rs.body = []byte{}
	}
	resp, cancel, err := c.do(ctx, rs)
	if err != nil {
		return err
	}
	defer cancel()
	if resp.StatusCode != 200 {
		return c.errorOf(rs, resp)
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, maxErrBody))
	resp.Body.Close()
	if et := unquote(resp.Header.Get("ETag")); isMD5Hex(et) && !strings.EqualFold(et, hx) {
		return &S3Error{Op: "put", Key: key, Status: 200, Code: "BadDigest"}
	}
	return nil
}

// createMultipart starts a multipart upload: its id
func (c *s3Client) createMultipart(ctx context.Context, key string) (string, error) {
	rs := reqSpec{op: "create upload", method: "POST", key: key, query: "uploads=", hdr: http.Header{"Content-Type": {"application/octet-stream"}}, timeout: time.Minute}
	resp, cancel, err := c.do(ctx, rs)
	if err != nil {
		return "", err
	}
	defer cancel()
	if resp.StatusCode != 200 {
		return "", c.errorOf(rs, resp)
	}
	var x struct {
		XMLName  xml.Name
		UploadID string `xml:"UploadId"`
	}
	if err := readXML(resp, maxSmallXML, &x); err != nil || x.XMLName.Local != "InitiateMultipartUploadResult" || !validUploadID(x.UploadID) {
		return "", &S3Error{Op: "create upload", Key: key, Status: 200, Code: "BadAnswer"}
	}
	return x.UploadID, nil
}

func validUploadID(s string) bool {
	if s == "" || len(s) > 1024 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] <= ' ' || s[i] >= 0x7f {
			return false
		}
	}
	return true
}

// uploadPart sends part n (1-based): its ETag, checked against the MD5 of what was sent
func (c *s3Client) uploadPart(ctx context.Context, key, id string, n int, body []byte) (string, error) {
	b64, hx := bodyMD5(body)
	rs := reqSpec{op: "upload part " + strconv.Itoa(n), method: "PUT", key: key,
		query: encodeQuery("partNumber", strconv.Itoa(n), "uploadId", id),
		hdr:   http.Header{"Content-Md5": {b64}}, body: body, timeout: xferTimeout(len(body))}
	resp, cancel, err := c.do(ctx, rs)
	if err != nil {
		return "", err
	}
	defer cancel()
	if resp.StatusCode != 200 {
		return "", c.errorOf(rs, resp)
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, maxErrBody))
	resp.Body.Close()
	et := unquote(resp.Header.Get("ETag"))
	if et == "" || len(et) > 256 {
		return "", &S3Error{Op: rs.op, Key: key, Status: 200, Code: "BadAnswer"}
	}
	if isMD5Hex(et) && !strings.EqualFold(et, hx) {
		return "", &S3Error{Op: rs.op, Key: key, Status: 200, Code: "BadDigest"}
	}
	return et, nil
}

type completedPart struct {
	XMLName    xml.Name `xml:"Part"`
	PartNumber int      `xml:"PartNumber"`
	ETag       string   `xml:"ETag"`
}

// completeMultipart joins the parts. S3 can answer 200 and still fail (an <Error> document as
// the body, after a long wait): the root element decides.
func (c *s3Client) completeMultipart(ctx context.Context, key, id string, parts []completedPart) (string, error) {
	var x struct {
		XMLName xml.Name        `xml:"CompleteMultipartUpload"`
		Parts   []completedPart `xml:"Part"`
	}
	x.Parts = parts
	for i := range x.Parts {
		x.Parts[i].ETag = `"` + x.Parts[i].ETag + `"`
	}
	body, err := xml.Marshal(x)
	if err != nil {
		return "", err
	}
	rs := reqSpec{op: "complete upload", method: "POST", key: key, query: encodeQuery("uploadId", id),
		hdr: http.Header{"Content-Type": {"application/xml"}}, body: body, timeout: 10 * time.Minute}
	resp, cancel, err := c.do(ctx, rs)
	if err != nil {
		return "", err
	}
	defer cancel()
	if resp.StatusCode != 200 {
		return "", c.errorOf(rs, resp)
	}
	var r struct {
		XMLName xml.Name
		ETag    string `xml:"ETag"`
		Code    string `xml:"Code"`
	}
	if err := readXML(resp, maxSmallXML, &r); err != nil {
		return "", &S3Error{Op: rs.op, Key: key, Status: 200, Code: "BadAnswer"}
	}
	if r.XMLName.Local != "CompleteMultipartUploadResult" {
		code := cleanCode(r.Code)
		if code == "" {
			code = "BadAnswer"
		}
		return "", &S3Error{Op: rs.op, Key: key, Status: 200, Code: code}
	}
	return unquote(r.ETag), nil
}

// abortMultipart drops an unfinished upload and its parts (gone already: fine)
func (c *s3Client) abortMultipart(ctx context.Context, key, id string) error {
	rs := reqSpec{op: "abort upload", method: "DELETE", key: key, query: encodeQuery("uploadId", id), timeout: time.Minute}
	resp, cancel, err := c.do(ctx, rs)
	if err != nil {
		return err
	}
	defer cancel()
	if resp.StatusCode == 204 || resp.StatusCode == 200 || resp.StatusCode == 404 {
		resp.Body.Close()
		return nil
	}
	return c.errorOf(rs, resp)
}

// objInfo is what HEAD and LIST say about an object.
type objInfo struct {
	Key      string
	Size     int64
	ETag     string
	Modified time.Time
}

// head: the object's size and ETag; ok false when there is none
func (c *s3Client) head(ctx context.Context, key string) (objInfo, bool, error) {
	rs := reqSpec{op: "head", method: "HEAD", key: key, timeout: time.Minute}
	resp, cancel, err := c.do(ctx, rs)
	if err != nil {
		return objInfo{}, false, err
	}
	defer cancel()
	resp.Body.Close()
	if resp.StatusCode == 404 {
		return objInfo{}, false, nil
	}
	if resp.StatusCode != 200 {
		return objInfo{}, false, c.errorOf(rs, resp)
	}
	mt, _ := http.ParseTime(resp.Header.Get("Last-Modified"))
	if resp.ContentLength < 0 {
		return objInfo{}, false, &S3Error{Op: "head", Key: key, Status: 200, Code: "BadAnswer"}
	}
	return objInfo{Key: key, Size: resp.ContentLength, ETag: unquote(resp.Header.Get("ETag")), Modified: mt}, true, nil
}

// getRange opens the object from byte off on. With ifMatch, a changed object is refused (a
// resume must not stitch two versions together). The body is the caller's to close.
func (c *s3Client) getRange(ctx context.Context, key string, off int64, ifMatch string) (io.ReadCloser, objInfo, error) {
	h := http.Header{}
	if off > 0 {
		h.Set("Range", "bytes="+strconv.FormatInt(off, 10)+"-")
	}
	if ifMatch != "" {
		h.Set("If-Match", `"`+ifMatch+`"`)
	}
	rs := reqSpec{op: "get", method: "GET", key: key, hdr: h, stream: true}
	resp, cancel, err := c.do(ctx, rs)
	if err != nil {
		return nil, objInfo{}, err
	}
	want := 200
	if off > 0 {
		want = 206
	}
	if resp.StatusCode != want {
		e := c.errorOf(rs, resp)
		cancel()
		if resp.StatusCode == 412 {
			e.Code = "ObjectChanged"
		}
		return nil, objInfo{}, e
	}
	info := objInfo{Key: key, ETag: unquote(resp.Header.Get("ETag"))}
	info.Size = resp.ContentLength + off
	if off > 0 {
		// Content-Range: bytes <off>-<end>/<total>
		cr := resp.Header.Get("Content-Range")
		var a, b, total int64
		if _, err := fmt.Sscanf(cr, "bytes %d-%d/%d", &a, &b, &total); err != nil || a != off || b != total-1 {
			resp.Body.Close()
			cancel()
			return nil, objInfo{}, &S3Error{Op: "get", Key: key, Status: 206, Code: "BadRange"}
		}
		info.Size = total
	}
	return &cancelBody{resp.Body, cancel}, info, nil
}

type cancelBody struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (b *cancelBody) Close() error { err := b.ReadCloser.Close(); b.cancel(); return err }

// getSmall reads a whole small object (a manifest), at most max bytes
func (c *s3Client) getSmall(ctx context.Context, key string, max int64) ([]byte, error) {
	rc, info, err := c.getRange(ctx, key, 0, "")
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	if info.Size > max {
		return nil, &S3Error{Op: "get", Key: key, Status: 200, Code: "TooLarge"}
	}
	b, err := io.ReadAll(io.LimitReader(rc, max+1))
	if err != nil {
		return nil, &S3Error{Op: "get", Key: key, Err: err}
	}
	if int64(len(b)) > max || (info.Size >= 0 && int64(len(b)) != info.Size) {
		return nil, &S3Error{Op: "get", Key: key, Status: 200, Code: "Truncated"}
	}
	return b, nil
}

// del removes an object (gone already: fine)
func (c *s3Client) del(ctx context.Context, key string) error {
	rs := reqSpec{op: "delete", method: "DELETE", key: key, timeout: time.Minute}
	resp, cancel, err := c.do(ctx, rs)
	if err != nil {
		return err
	}
	defer cancel()
	if resp.StatusCode == 204 || resp.StatusCode == 200 || resp.StatusCode == 404 {
		resp.Body.Close()
		return nil
	}
	return c.errorOf(rs, resp)
}

// listPage is one ListObjectsV2 answer.
type listPage struct {
	Objects  []objInfo
	Prefixes []string
	Next     string // continuation token; "" at the end
}

type xmlList struct {
	XMLName  xml.Name
	Contents []struct {
		Key          string `xml:"Key"`
		Size         int64  `xml:"Size"`
		ETag         string `xml:"ETag"`
		LastModified string `xml:"LastModified"`
	} `xml:"Contents"`
	CommonPrefixes []struct {
		Prefix string `xml:"Prefix"`
	} `xml:"CommonPrefixes"`
	IsTruncated           bool   `xml:"IsTruncated"`
	NextContinuationToken string `xml:"NextContinuationToken"`
}

// parseList checks a ListObjectsV2 document: every key under prefix, sane sizes, at most 1000
// entries, a token when truncated. A store that answers otherwise is refused, not believed.
func parseList(b []byte, prefix string) (listPage, error) {
	var x xmlList
	if err := xml.Unmarshal(b, &x); err != nil {
		return listPage{}, fmt.Errorf("bad list answer: %w", err)
	}
	if x.XMLName.Local != "ListBucketResult" {
		return listPage{}, errors.New("bad list answer: " + cleanCode(x.XMLName.Local))
	}
	if len(x.Contents)+len(x.CommonPrefixes) > 1000 {
		return listPage{}, errors.New("bad list answer: more than 1000 entries")
	}
	var p listPage
	for _, o := range x.Contents {
		if len(o.Key) > maxKeyLen || !strings.HasPrefix(o.Key, prefix) || o.Size < 0 {
			return listPage{}, errors.New("bad list answer: an entry outside the prefix or with a bad size")
		}
		mt, _ := time.Parse(time.RFC3339Nano, o.LastModified)
		p.Objects = append(p.Objects, objInfo{Key: o.Key, Size: o.Size, ETag: unquote(o.ETag), Modified: mt})
	}
	for _, cp := range x.CommonPrefixes {
		if len(cp.Prefix) > maxKeyLen || !strings.HasPrefix(cp.Prefix, prefix) {
			return listPage{}, errors.New("bad list answer: a common prefix outside the prefix")
		}
		p.Prefixes = append(p.Prefixes, cp.Prefix)
	}
	if x.IsTruncated {
		if x.NextContinuationToken == "" || len(x.NextContinuationToken) > 4096 {
			return listPage{}, errors.New("bad list answer: truncated without a continuation token")
		}
		p.Next = x.NextContinuationToken
	}
	return p, nil
}

// listPage asks for one page
func (c *s3Client) listOne(ctx context.Context, prefix, delim, token string, max int) (listPage, error) {
	q := []string{"list-type", "2", "prefix", prefix, "max-keys", strconv.Itoa(max)}
	if delim != "" {
		q = append(q, "delimiter", delim)
	}
	if token != "" {
		q = append(q, "continuation-token", token)
	}
	rs := reqSpec{op: "list", method: "GET", key: "", query: encodeQuery(q...), timeout: 2 * time.Minute}
	resp, cancel, err := c.do(ctx, rs)
	if err != nil {
		return listPage{}, err
	}
	defer cancel()
	if resp.StatusCode != 200 {
		return listPage{}, c.errorOf(rs, resp)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxListBody+1))
	resp.Body.Close()
	if err != nil {
		return listPage{}, &S3Error{Op: "list", Err: err}
	}
	if len(b) > maxListBody {
		return listPage{}, &S3Error{Op: "list", Status: 200, Code: "TooLarge"}
	}
	p, err := parseList(b, prefix)
	if err != nil {
		return listPage{}, &S3Error{Op: "list", Status: 200, Code: "BadAnswer", Err: err}
	}
	return p, nil
}

// list: every object (and common prefix) under prefix, at most maxPages pages
func (c *s3Client) list(ctx context.Context, prefix, delim string, maxPages int) (listPage, error) {
	var all listPage
	token := ""
	for i := 0; i < maxPages; i++ {
		p, err := c.listOne(ctx, prefix, delim, token, 1000)
		if err != nil {
			return listPage{}, err
		}
		all.Objects = append(all.Objects, p.Objects...)
		all.Prefixes = append(all.Prefixes, p.Prefixes...)
		if p.Next == "" {
			return all, nil
		}
		if p.Next == token {
			return listPage{}, &S3Error{Op: "list", Status: 200, Code: "BadAnswer"}
		}
		token = p.Next
	}
	return listPage{}, &S3Error{Op: "list", Status: 200, Code: "TooMany"}
}

// readXML decodes a bounded answer and closes it
func readXML(resp *http.Response, max int64, v any) error {
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, max+1))
	if err != nil {
		return err
	}
	if int64(len(b)) > max {
		return errors.New("answer too large")
	}
	return xml.Unmarshal(b, v)
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}
