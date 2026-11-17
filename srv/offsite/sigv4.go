package offsite

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"sort"
	"strings"
	"time"
)

// AWS Signature Version 4 (header form), as S3 and every S3-compatible store (R2, B2, MinIO)
// check it: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
// Tested against AWS's published vectors (testdata/sigv4).

const (
	sigAlgorithm = "AWS4-HMAC-SHA256"
	amzDateForm  = "20060102T150405Z"
	// emptySHA256 is the payload hash of a request without a body
	emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
)

type signer struct {
	access, secret, region, service string
}

// signedHeader: the headers that are signed when present. host always; every x-amz-*; the
// ones whose change would change the meaning of a request.
func signedHeader(name string) bool {
	switch name {
	case "host", "content-md5", "content-type", "range", "date", "if-match":
		return true
	}
	return strings.HasPrefix(name, "x-amz-")
}

// sign sets X-Amz-Date and Authorization. canonURI is the path as sent (already URI-encoded,
// see encodePath); the query comes from req.URL.RawQuery. The caller sets X-Amz-Content-Sha256
// (S3 requires it and signs it) to payloadHash beforehand.
func (s signer) sign(req *http.Request, canonURI, payloadHash string, t time.Time) {
	amzDate := t.UTC().Format(amzDateForm)
	req.Header.Set("X-Amz-Date", amzDate)
	creq, signed := canonicalRequest(req, canonURI, payloadHash)
	scope := amzDate[:8] + "/" + s.region + "/" + s.service + "/aws4_request"
	sts := stringToSign(amzDate, scope, creq)
	sig := hex.EncodeToString(hmacSHA(s.signingKey(amzDate[:8]), sts))
	req.Header.Set("Authorization", sigAlgorithm+" Credential="+s.access+"/"+scope+
		", SignedHeaders="+signed+", Signature="+sig)
}

func (s signer) signingKey(date string) []byte {
	k := hmacSHA([]byte("AWS4"+s.secret), date)
	k = hmacSHA(k, s.region)
	k = hmacSHA(k, s.service)
	return hmacSHA(k, "aws4_request")
}

func stringToSign(amzDate, scope, creq string) string {
	h := sha256.Sum256([]byte(creq))
	return sigAlgorithm + "\n" + amzDate + "\n" + scope + "\n" + hex.EncodeToString(h[:])
}

func hmacSHA(key []byte, data string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(data))
	return m.Sum(nil)
}

// canonicalRequest returns the canonical request and the signed header list.
func canonicalRequest(req *http.Request, canonURI, payloadHash string) (string, string) {
	host := req.Host
	if host == "" {
		host = req.URL.Host
	}
	hs := map[string][]string{"host": {host}}
	for k, vs := range req.Header {
		lk := strings.ToLower(k)
		if lk == "host" || !signedHeader(lk) {
			continue
		}
		hs[lk] = append(hs[lk], vs...)
	}
	names := make([]string, 0, len(hs))
	for k := range hs {
		names = append(names, k)
	}
	sort.Strings(names)
	var ch strings.Builder
	for _, k := range names {
		vals := make([]string, len(hs[k]))
		for i, v := range hs[k] {
			vals[i] = trimAll(v)
		}
		ch.WriteString(k + ":" + strings.Join(vals, ",") + "\n")
	}
	signed := strings.Join(names, ";")
	if canonURI == "" {
		canonURI = "/"
	}
	return req.Method + "\n" + canonURI + "\n" + canonicalQuery(req.URL.RawQuery) + "\n" +
		ch.String() + "\n" + signed + "\n" + payloadHash, signed
}

// trimAll: leading and trailing spaces off, inner runs of spaces as one (SigV4's header rule)
func trimAll(v string) string { return strings.Join(strings.Fields(v), " ") }

// canonicalQuery: each name and value URI-encoded, sorted by name then value; a name without a
// value is "name=". The raw query is decoded first so a parameter is encoded exactly once.
func canonicalQuery(raw string) string {
	if raw == "" {
		return ""
	}
	type kv struct{ k, v string }
	var ps []kv
	for _, p := range strings.Split(raw, "&") {
		if p == "" {
			continue
		}
		k, v, _ := strings.Cut(p, "=")
		ps = append(ps, kv{uriEncode(unescape(k), true), uriEncode(unescape(v), true)})
	}
	sort.Slice(ps, func(i, j int) bool {
		if ps[i].k != ps[j].k {
			return ps[i].k < ps[j].k
		}
		return ps[i].v < ps[j].v
	})
	parts := make([]string, len(ps))
	for i, p := range ps {
		parts[i] = p.k + "=" + p.v
	}
	return strings.Join(parts, "&")
}

// unescape is percent-decoding without "+" as a space (SigV4 queries are built by encodeQuery,
// which never writes "+" for a space)
func unescape(s string) string {
	if !strings.Contains(s, "%") {
		return s
	}
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) && isHex(s[i+1]) && isHex(s[i+2]) {
			b = append(b, unhex(s[i+1])<<4|unhex(s[i+2]))
			i += 2
			continue
		}
		b = append(b, s[i])
	}
	return string(b)
}

func isHex(c byte) bool { return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F' }
func unhex(c byte) byte {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	}
	return c - 'A' + 10
}

// uriEncode is SigV4's UriEncode: unreserved characters (A-Z a-z 0-9 - . _ ~) as they are,
// every other byte as %XX (upper case); "/" kept when it separates path segments.
func uriEncode(s string, encodeSlash bool) string {
	const hexd = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '-', c == '.', c == '_', c == '~':
			b.WriteByte(c)
		case c == '/' && !encodeSlash:
			b.WriteByte(c)
		default:
			b.WriteByte('%')
			b.WriteByte(hexd[c>>4])
			b.WriteByte(hexd[c&15])
		}
	}
	return b.String()
}

// encodeQuery builds a raw query from name/value pairs (in the order given; the signer sorts)
func encodeQuery(pairs ...string) string {
	var parts []string
	for i := 0; i+1 < len(pairs); i += 2 {
		parts = append(parts, uriEncode(pairs[i], true)+"="+uriEncode(pairs[i+1], true))
	}
	return strings.Join(parts, "&")
}
