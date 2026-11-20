package logs

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
)

// entry: one journalctl -o json line of the app
func entry(i int, unit, msg string) string {
	m, _ := json.Marshal(msg)
	return fmt.Sprintf(`{"__CURSOR":"s=a;i=%x","__REALTIME_TIMESTAMP":"%d","MESSAGE":%s,"PRIORITY":"6","_SYSTEMD_UNIT":%q,"_PID":"7"}`,
		i, int64(1794580000+i)*1000000, m, unit)
}

// journal answers journalctl with these entries (oldest first; reversed for -r) and counts how
// many it was asked for.
func (h *host) journal(entries ...string) {
	h.cmd = func(argv []string) (string, error) {
		if argv[0] != "journalctl" || slices.Contains(argv, "cat") {
			return "", nil
		}
		e := slices.Clone(entries)
		if slices.Contains(argv, "-r") {
			slices.Reverse(e)
		}
		if len(e) == 0 {
			return "", nil
		}
		return strings.Join(e, "\n") + "\n", nil
	}
}

func (h *host) query(stdin string, args ...string) (string, error) {
	var b bytes.Buffer
	w := bufio.NewWriter(&b)
	err := h.l.Query(context.Background(), "filt", append([]string{"spec"}, args...), strings.NewReader(stdin), w)
	w.Flush()
	return b.String(), err
}

func TestSpec(t *testing.T) {
	h := newHost(t)
	h.app("filt")
	for in, msg := range map[string]string{
		strings.Repeat("n=1\n", 31): "spec too long", "nokey\n": "bad spec line", "grep=a\x01b\n": "control characters in grep",
		"shell=id\n": "unknown spec key: shell", "n=-1\n": "bad value for n", "n=1;id\n": "bad value for n",
		"since=$(id)\n": "bad value for since", "after=s=1;rm -rf /\n": "bad value for after", "level=8\n": "bad value for level",
		"release=../x\n": "bad value for release", "grep=" + strings.Repeat("x", 257) + "\n": "bad value for grep",
		"grep=a(b\ngrep_mode=regex\n": "bad regular expression", "grep=\u0085\n": "control characters in grep",
		"tz=+7\n": "bad value for tz", "format=xml\n": "bad value for format", "grep=" + strings.Repeat("y", 5000) + "\n": "bad value for grep",
	} {
		_, err := h.query(in)
		wantErr(t, err, msg)
	}
	// a last line without its newline is not read (bash's read)
	h.journal(entry(1, "tando-filt.service", "one"), entry(2, "tando-filt.service", "two"))
	if o, err := h.query("n=1\nbogus"); err != nil || !strings.HasSuffix(o, " two\n") || strings.Count(o, "\n") != 1 {
		t.Fatal(o, err)
	}
	if o, err := h.query("n=0\n"); err != nil || o != "" {
		t.Fatal("n=0 prints nothing", o)
	}
	if o, err := h.query("n=00\n"); err != nil || o != "" {
		t.Fatal("n=00 is 0 too", o)
	}
}

func TestQuery(t *testing.T) {
	h := newHost(t)
	h.app("filt", "job.backup=0 3 * * *|x", "job.Bad Name=x|y")
	h.write("etc/systemd/journald@tando-filt.conf", "x")
	var es []string
	for i := 1; i <= 6; i++ {
		es = append(es, entry(i, "tando-filt.service", fmt.Sprintf("line %d alpha", i)))
	}
	es = append(es, entry(7, "tando-other.service", "not ours"), `not json`,
		`{"__CURSOR":"s=a;i=8","__REALTIME_TIMESTAMP":"1794580008000000","MESSAGE":"Started x","PRIORITY":"6","_PID":"1","UNIT":"tando-filt.service"}`,
		entry(9, "tando-filt-job-backup.service", "ERROR job \u001b failed"))
	h.journal(es...)
	o, err := h.query("n=3\nsince=@1794580000\nuntil=-60\ngrep=alpha\ntz=+0700\n")
	if err != nil {
		t.Fatal(err)
	}
	want := "2026-11-13 21:26:44 line 4 alpha\n2026-11-13 21:26:45 line 5 alpha\n2026-11-13 21:26:46 line 6 alpha\n"
	if o != want {
		t.Fatalf("got\n%s", o)
	}
	jc := h.argvs("journalctl")[0]
	for _, s := range []string{"--namespace=+tando-filt", "-u tando-filt.service -u systemd-journald@tando-filt.service -u tando-filt-job-backup.service ",
		"--since=@1794580000", "--until=@1794589940", "--grep=alpha --case-sensitive=yes", " -r"} {
		if !strings.Contains(jc+" ", s) {
			t.Fatalf("%q not in %s", s, jc)
		}
	}
	if strings.Contains(jc, "Bad") {
		t.Fatal("a job name the agent would refuse became a unit:", jc)
	}
	// every line, levels, systemd's own line, a job; cursors; JSON
	h.calls = nil
	o, _ = h.query("n=all\ncursor=1\nformat=json\n")
	if strings.Count(o, "\n") != 8 || !strings.Contains(o, `"src":"systemd","unit":"tando-filt.service"`) ||
		!strings.Contains(o, `"src":"job:backup"`) || !strings.Contains(o, `"level":"err","msg":"ERROR job ^[ failed"`) ||
		!strings.HasPrefix(o, "s=a;i=1\t{") || strings.Contains(h.argvs("journalctl")[0], " -r") {
		t.Fatal(o)
	}
	o, _ = h.query("level=3\n")
	if o != "2026-11-13 14:26:49 ERR [job:backup] ERROR job ^[ failed\n" {
		t.Fatalf("%q", o)
	}
	o, _ = h.query("grep=LINE [56]\ngrep_mode=iregex\n")
	if strings.Count(o, "\n") != 2 {
		t.Fatalf("%q", o)
	}
	// not a literal journalctl can be given (it could match the ^X notation)
	h.calls = nil
	h.query("grep=^[\ngrep_mode=fixed\n")
	if strings.Contains(h.argvs("journalctl")[0], "--grep") {
		t.Fatal(h.argvs("journalctl"))
	}
	h.query("grep=a.b c\ngrep_mode=ifixed\n")
	if j := h.argvs("journalctl"); !strings.Contains(j[len(j)-1], `--grep=a\.b\ c --case-sensitive=no`) {
		t.Fatal(h.argvs("journalctl"))
	}
	// the old form
	var b bytes.Buffer
	w := bufio.NewWriter(&b)
	wantErr(t, h.l.Query(context.Background(), "filt", []string{"5;id"}, nil, w), "bad count")
	wantErr(t, h.l.Query(context.Background(), "../x", nil, nil, w), "invalid app name")
}

func TestRelease(t *testing.T) {
	h := newHost(t)
	h.app("filt")
	// time id kind result total build upload copy preflight switch verify note
	h.write("opt/apps/filt/history.tsv", strings.Join([]string{
		"1794580010\t20261108-000001\tdeploy\tok\t9\t-\t-\t1\t2\t0\t3\t-",
		"1794580040\t20261108-000002\tdeploy\tok\t9\t-\t-\t1\t2\t0\t4\tv2",
		"1794580070\t20261108-000003\tdeploy\trolledback\t9\t-\t-\t1\t2\t0\t5\tverify failed",
		"1794580090\t20261108-000004\tdeploy\tfailed\t9\t-\t-\t1\t2\t0\t-\tpre-flight \x1b failed",
	}, "\n")+"\n")
	a, _ := h.l.app("filt")
	r := a.releaseRanges("20261108-000002", h.now)
	if fmt.Sprint(r) != fmt.Sprint([][2]float64{{1794580036e6, 1794580065e6}, {1794580070e6, float64(h.now+1) * 1e6}}) {
		t.Fatalf("%v", r)
	}
	if r := a.releaseRanges("20261108-000003", h.now); fmt.Sprint(r) != "[[1.794580065e+15 1.79458007e+15]]" {
		t.Fatalf("a rolled back release was live during its verify: %v", r)
	}
	if id, ts := a.liveRelease(); id != "20261108-000002" || ts != 1794580070 {
		t.Fatal(id, ts)
	}
	if s := a.switches(); len(s) != 2 || s[1].T != 1794580036 {
		t.Fatal(s)
	}
	h.journal(entry(37, "tando-filt.service", "R2"))
	o, err := h.query("release=20261108-000002\n")
	if err != nil || !strings.HasPrefix(o, "# release 20261108-000002 was live: ") || !strings.Contains(o, " (server time)\n") ||
		!strings.Contains(h.argvs("journalctl")[0], "--since=@1794580036 --until=@1794590001") {
		t.Fatal(o, err, h.argvs("journalctl"))
	}
	o, err = h.query("release=20261108-000004\n")
	if err != nil || !strings.HasPrefix(o, "# release 20261108-000004 was never live: its deploy log (activation, build, pre-flight, release command)\n"+
		"# deploy 20261108-000004: failed (9s: copy 1, pre-flight 2, switch 0, verify -) - pre-flight  failed\n") {
		t.Fatalf("%q %v", o, err)
	}
	if j := h.argvs("journalctl"); !strings.Contains(j[len(j)-1], "-u tando-filt-act-20261108-000004.service -u tando-filt-venv-20261108-000004.service -u tando-filt-pre-20261108-000004.service -u tando-filt-rel-20261108-000004.service") {
		t.Fatal(h.argvs("journalctl"))
	}
	_, err = h.query("release=20200101-000000\n")
	wantErr(t, err, "no such release: 20200101-000000")
}

func TestSuppressedNote(t *testing.T) {
	h := newHost(t)
	h.app("filt", "log_rate=0500/030s")
	h.cmd = func(argv []string) (string, error) {
		if slices.Contains(argv, "cat") {
			return "Suppressed 100 messages from tando-filt.service\nSuppressed 23 messages from tando-filt.service\n", nil
		}
		return entry(1, "tando-filt.service", "x") + "\n", nil
	}
	o, _ := h.query("n=5\nuntil=@1794590000\n")
	if !strings.HasSuffix(o, "# note: journald dropped 123 lines in this window (over log_rate 500/30s)\n") {
		t.Fatalf("%q", o)
	}
	if !strings.Contains(h.argvs("journalctl")[1], "--since=@1794580001 -g ^Suppressed [0-9]+ messages --until=@1794590000") {
		t.Fatal(h.argvs("journalctl"))
	}
}

func TestFollow(t *testing.T) {
	h := newHost(t)
	h.app("filt")
	h.journal(entry(1, "tando-filt.service", "a"), entry(2, "tando-other.service", "b"))
	o, err := h.query("n=5\nfollow=1\ncursor=1\n")
	j := h.argvs("journalctl")
	if err != nil || len(j) != 2 || !strings.HasSuffix(j[1], "-f --lines=all --after-cursor=s=a;i=2") || strings.Count(o, "s=a;i=1\t") != 2 {
		t.Fatal(o, err, j)
	}
	h.calls = nil
	h.query("after=s=0a;i=1f\nfollow=1\n")
	if j := h.argvs("journalctl"); len(j) != 1 || !strings.HasSuffix(j[0], "--after-cursor=s=0a;i=1f") {
		t.Fatal(j)
	}
	h.calls = nil
	h.query("n=0\nfollow=1\n")
	if j := h.argvs("journalctl"); len(j) != 1 || !strings.HasSuffix(j[0], "-f -n 0") {
		t.Fatal(j)
	}
}

func TestQuietWhenNothingMatched(t *testing.T) {
	h := newHost(t)
	h.app("filt")
	h.cmd = func([]string) (string, error) { return "", errors.New("journalctl: exit status 1") }
	if o, err := h.query("grep=nothing\n"); err != nil || o != "" || h.stderr.Len() != 0 {
		t.Fatalf("%q %v %q", o, err, h.stderr.String())
	}
	h.cmd = func([]string) (string, error) {
		return "", errors.New("journalctl: exit status 1: Failed to seek to cursor")
	}
	h.query("n=1\n")
	if h.stderr.String() != "tando-logs: journalctl: exit status 1: Failed to seek to cursor\n" {
		t.Fatalf("%q", h.stderr.String())
	}
}
