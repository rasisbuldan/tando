package logs

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"tando/srv/internal/out"
	"tando/srv/internal/out/outtest"
)

// entryBytes: an entry as journald writes one whose MESSAGE is not printable UTF-8 (a control
// character, DEL, C1, invalid UTF-8): a JSON array of its bytes.
func entryBytes(i int, unit string, msg []byte) string {
	var b strings.Builder
	for k, c := range msg {
		if k > 0 {
			b.WriteByte(',')
		}
		fmt.Fprint(&b, c)
	}
	return fmt.Sprintf(`{"__CURSOR":"s=a;i=%x","__REALTIME_TIMESTAMP":"%d","MESSAGE":[%s],"PRIORITY":"6","_SYSTEMD_UNIT":%q,"_PID":"7"}`,
		i, int64(1794580000+i)*1000000, b.String(), unit)
}

// tando-logs prints rows through its out.Writer, and journal lines through its Stream (text that
// is not rows): journal.Filter neutralises every message on the way, as the shell's awk did
// (golden-tested): C0 controls become ^X, DEL ^?, bytes that are not printable UTF-8 (C1
// controls) \xHH, in text and in JSON. A bidi override in a printable message is kept, as the
// shell kept it; the client's lx_clean drops it (srv/README.md, Output).
func TestOutputClean(t *testing.T) {
	h := newHost(t)
	h.app("filt")
	h.journal(entryBytes(1, "tando-filt.service", []byte(outtest.Hostile+"\ttab\nnewline")),
		entry(2, "tando-filt.service", "bidi ‮evil⁦ kept"), entry(3, "tando-filt.service", "plain"))
	for _, spec := range []string{"n=10\n", "n=all\n", "n=10\nformat=json\n", "n=all\nformat=json\n", "n=10\ngrep=evil\n"} {
		o, err := h.query(spec)
		if err != nil {
			t.Fatal(spec, err)
		}
		if err := outtest.CheckControls([]byte(o)); err != nil {
			t.Errorf("%q: %v", spec, err)
		}
		if !strings.Contains(o, `^[[31m^G`) || !strings.Contains(o, `xc2`) || !strings.Contains(o, "\u202eevil") {
			t.Errorf("%q: not shown as the shell showed it: %q", spec, o)
		}
	}
	// the old form, through the out.Writer's Stream as main passes it
	var b bytes.Buffer
	w := out.New(&b)
	if err := h.l.Query(ctx(), "filt", []string{"5"}, nil, w.Stream()); err != nil {
		t.Fatal(err)
	}
	w.Flush()
	if err := outtest.CheckControls(b.Bytes()); err != nil || !strings.Contains(b.String(), "^[[31m") {
		t.Errorf("old form: %v %q", err, b.String())
	}
	// unit-props and caddy-log print text made of checked values only: a hostile app name is
	// refused before anything is printed
	b.Reset()
	bw := bufio.NewWriter(&b)
	if h.l.UnitProps(outtest.Hostile, bw) == nil || h.l.CaddyLog(ctx(), outtest.Hostile, bw) == nil {
		t.Error("a hostile app name was accepted")
	}
	bw.Flush()
	if b.Len() != 0 {
		t.Errorf("printed %q", b.String())
	}
}

// Rows of tando-logs (here the request log's tail and errors, with hostile paths) go through the
// out.Writer and come out clean, bidi included.
func TestRowsClean(t *testing.T) {
	h := newHost(t)
	h.app("req")
	n := float64(h.now)
	line := func(ts float64, status int, uri string) string { // (reqLine's %q is not JSON for these bytes)
		u, _ := json.Marshal(uri)
		return strings.Replace(reqLine(ts, status, "URI"), `"URI"`, string(u), 1)
	}
	h.access("req", "access.log", h.now, false, line(n-100, 500, "/"+outtest.Hostile), line(n-50, 404, "/b\t"+outtest.Hostile),
		line(n-10, 200, "/ok"))
	for name, verb := range map[string]func(w *out.Writer) error{
		"req-tail":    func(w *out.Writer) error { return h.l.ReqTail(ctx(), "req", "10", "", w, nil) },
		"req-errors":  func(w *out.Writer) error { return h.l.ReqErrors(ctx(), "req", "3600", "10", "4xx", w) },
		"req-summary": func(w *out.Writer) error { return h.l.ReqSummary(ctx(), "req", "3600", w) },
	} {
		o, err := h.rows(verb)
		if err != nil {
			t.Fatal(name, err)
		}
		if err := outtest.Check([]byte(o)); err != nil {
			t.Errorf("%s: %v", name, err)
		}
		if name != "req-summary" && !strings.Contains(o, "evil") {
			t.Errorf("%s: the hostile path is not shown: %q", name, o)
		}
	}
}
