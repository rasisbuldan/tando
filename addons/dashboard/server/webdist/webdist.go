// Package webdist: the built web app (addons/dashboard/web, M2), embedded in tando-dash. Vite
// writes it into dist/ here; until then dist/ holds a placeholder page. theme.js is a file of
// its own (no inline script under the CSP): it sets the theme class before first paint.
package webdist

import (
	"embed"
	"io/fs"
	"mime"
	"net/http"
	"path"
	"strings"
)

//go:embed all:dist
var files embed.FS

// FS: the files, rooted at dist
func FS() fs.FS {
	f, err := fs.Sub(files, "dist")
	if err != nil {
		panic(err)
	}
	return f
}

// Handler: GET of the app's files; a path without an extension that is not a file is a route
// of the app (/s/web-1, /deploys) and gets index.html; an unknown file is 404
func Handler(root fs.FS) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
		if p == "" {
			p = "index.html"
		}
		b, err := fs.ReadFile(root, p)
		if err != nil {
			if path.Ext(p) != "" {
				http.NotFound(w, r)
				return
			}
			p = "index.html"
			if b, err = fs.ReadFile(root, p); err != nil {
				http.NotFound(w, r)
				return
			}
		}
		ct := mime.TypeByExtension(path.Ext(p))
		if ct == "" {
			ct = "application/octet-stream"
		}
		w.Header().Set("Content-Type", ct)
		if strings.HasPrefix(p, "assets/") { // Vite's hashed file names
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		} else {
			w.Header().Set("Cache-Control", "no-cache")
		}
		if r.Method == http.MethodHead {
			return
		}
		_, _ = w.Write(b)
	})
}
