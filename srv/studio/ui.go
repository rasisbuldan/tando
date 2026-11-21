package studio

import (
	"bytes"
	"compress/gzip"
	"embed"
	"fmt"
	"net/http"
	"strings"
)

// The page: three files, no framework, nothing from outside (it works offline). Byte budgets
// in ui_test.go: index.html 4 KB, s.css 8 KB, s.js 40 KB, 52 KB in all, 18 KB gzipped.
//
//go:embed ui/index.html ui/s.css ui/s.js
var uiFS embed.FS

type asset struct {
	typ     string
	raw, gz []byte
}

func assets() map[string]asset {
	m := map[string]asset{}
	for path, f := range map[string][2]string{"/": {"ui/index.html", "text/html; charset=utf-8"},
		"/s.css": {"ui/s.css", "text/css; charset=utf-8"}, "/s.js": {"ui/s.js", "text/javascript; charset=utf-8"}} {
		b, err := uiFS.ReadFile(f[0])
		if err != nil {
			panic(err)
		}
		var z bytes.Buffer
		zw, _ := gzip.NewWriterLevel(&z, gzip.BestCompression)
		zw.Write(b)
		zw.Close()
		m[path] = asset{typ: f[1], raw: b, gz: z.Bytes()}
	}
	return m
}

func (s *Studio) serveStatic(w http.ResponseWriter, r *http.Request) {
	serveStatic(w, r, s.static, s.probe)
}

// serveStatic: the page's three files and /healthz (the probe word: the client reached this
// studio, not another listener on the port)
func serveStatic(w http.ResponseWriter, r *http.Request, static map[string]asset, probe string) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		apiErr(w, 405, "bad_request", "GET")
		return
	}
	if r.URL.Path == "/healthz" { // the client's probe: it reached this studio, not another listener
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintf(w, "tando-studio %s\n", probe)
		return
	}
	a, ok := static[r.URL.Path]
	if !ok {
		apiErr(w, 404, "not_found", "not found")
		return
	}
	w.Header().Set("Content-Type", a.typ)
	w.Header().Set("Vary", "Accept-Encoding")
	body := a.raw
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		w.Header().Set("Content-Encoding", "gzip")
		body = a.gz
	}
	w.Header().Set("Content-Length", fmt.Sprint(len(body)))
	if r.Method == http.MethodGet {
		w.Write(body)
	}
}
