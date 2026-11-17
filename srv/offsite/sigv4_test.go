package offsite

import (
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestSigV4Vectors signs each request of testdata/sigv4 and compares the Authorization header
// (and the canonical request where the vector gives it) with AWS's published values.
func TestSigV4Vectors(t *testing.T) {
	files, _ := filepath.Glob("testdata/sigv4/*")
	n := 0
	for _, f := range files {
		if filepath.Base(f) == "README" {
			continue
		}
		n++
		t.Run(filepath.Base(f), func(t *testing.T) {
			b, err := os.ReadFile(f)
			if err != nil {
				t.Fatal(err)
			}
			head, creqWant, _ := strings.Cut(string(b), "--- creq\n")
			v := map[string]string{}
			var hdrs []string
			for _, l := range strings.Split(head, "\n") {
				k, val, ok := strings.Cut(l, ": ")
				if !ok {
					continue
				}
				if k == "header" {
					hdrs = append(hdrs, val)
				} else {
					v[k] = val
				}
			}
			s := signer{access: v["access"], secret: v["secret"], region: v["region"], service: v["service"]}
			u := &url.URL{Scheme: "https", Host: v["host"], Path: v["path"], RawQuery: v["query"]}
			req := &http.Request{Method: v["method"], URL: u, Header: http.Header{}, Host: v["host"]}
			for _, h := range hdrs {
				k, val, _ := strings.Cut(h, ": ")
				req.Header.Add(k, val)
			}
			tm, err := time.Parse(amzDateForm, v["date"])
			if err != nil {
				t.Fatal(err)
			}
			canon := encodePath(v["path"])
			s.sign(req, canon, v["payload"], tm)
			if got := req.Header.Get("Authorization"); got != v["authz"] {
				creq, _ := canonicalRequest(req, canon, v["payload"])
				t.Errorf("authorization\n got %s\nwant %s\ncanonical request:\n%s", got, v["authz"], creq)
			}
			if creqWant != "" {
				creq, _ := canonicalRequest(req, canon, v["payload"])
				if creq != strings.TrimRight(creqWant, "\n") {
					t.Errorf("canonical request\n got %q\nwant %q", creq, strings.TrimRight(creqWant, "\n"))
				}
			}
		})
	}
	if n < 7 {
		t.Fatalf("only %d vectors in testdata/sigv4", n)
	}
}

func TestURIEncode(t *testing.T) {
	for _, c := range []struct{ in, slash, noslash string }{
		{"a/b c", "a%2Fb%20c", "a/b%20c"},
		{"~._-AZaz09", "~._-AZaz09", "~._-AZaz09"},
		{"é+=&", "%C3%A9%2B%3D%26", "%C3%A9%2B%3D%26"},
	} {
		if g := uriEncode(c.in, true); g != c.slash {
			t.Errorf("uriEncode(%q, true) = %q, want %q", c.in, g, c.slash)
		}
		if g := uriEncode(c.in, false); g != c.noslash {
			t.Errorf("uriEncode(%q, false) = %q, want %q", c.in, g, c.noslash)
		}
	}
	if g := canonicalQuery("b=2&a=x%2Fy&a=1&list-type=2&uploads"); g != "a=1&a=x%2Fy&b=2&list-type=2&uploads=" {
		t.Errorf("canonicalQuery = %q", g)
	}
}
