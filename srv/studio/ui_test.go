package studio

import (
	"bytes"
	"compress/gzip"
	"regexp"
	"strings"
	"testing"
)

// The page's byte budgets (docs/ARCHITECTURE.md "db studio"): a test, not a hope.
func TestPageBudget(t *testing.T) {
	budget := map[string]int{"ui/index.html": 4096, "ui/s.css": 8192, "ui/s.js": 40960}
	total, gz := 0, 0
	for f, max := range budget {
		b, err := uiFS.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if len(b) > max {
			t.Errorf("%s: %d bytes, budget %d", f, len(b), max)
		}
		total += len(b)
		var z bytes.Buffer
		w, _ := gzip.NewWriterLevel(&z, gzip.BestCompression)
		w.Write(b)
		w.Close()
		gz += z.Len()
	}
	if total > 52*1024 || gz > 18*1024 {
		t.Errorf("page: %d bytes raw (budget 53248), %d gzipped (budget 18432)", total, gz)
	}
	t.Logf("page: %d bytes raw, %d gzipped", total, gz)
}

// Database content reaches the page through textContent only: no HTML sink, no eval, no inline
// script or handler, nothing loaded from elsewhere.
func TestPageHasNoHTMLSinks(t *testing.T) {
	js, _ := uiFS.ReadFile("ui/s.js")
	html, _ := uiFS.ReadFile("ui/index.html")
	css, _ := uiFS.ReadFile("ui/s.css")
	for _, bad := range []string{"innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function",
		"setAttribute('style'", `setAttribute("style"`, "srcdoc", "javascript:", "createContextualFragment", "DOMParser", "setTimeout('", `setTimeout("`} {
		if bytes.Contains(js, []byte(bad)) {
			t.Errorf("s.js uses %s", bad)
		}
	}
	if m := regexp.MustCompile(`(?i)<script(?:[^>]*)>[^<]|\son[a-z]+=|style=|https?://`).Find(html); m != nil {
		t.Errorf("index.html has inline script, a handler, a style attribute or an outside URL: %q", m)
	}
	for _, f := range [][]byte{js, css} {
		if regexp.MustCompile(`https?://|@import|url\(`).Match(f) {
			t.Error("a request to somewhere else")
		}
	}
	if !strings.Contains(string(html), `<script src="/s.js"></script>`) {
		t.Error("the script is not the page's own file")
	}
}
