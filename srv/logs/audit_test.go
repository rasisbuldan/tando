package logs

import (
	"os"
	"strings"
	"testing"

	"tando/srv/internal/out"
)

func TestAudit(t *testing.T) {
	h := newHost(t)
	env := map[string]string{"SUDO_USER": "vmadmin"}
	h.l.Getenv = func(k string) string { return env[k] }
	// the agent (pid 300) was started by sudo (200) in the ssh session (100)
	h.write("proc/300/stat", "300 (tando agent) S 200 1 1\n")
	h.write("proc/300/environ", "PATH=/bin\x00")
	h.write("proc/200/stat", "200 (sudo) S 100 1 1\n")
	h.write("proc/200/environ", "A=1\x00")
	h.write("proc/100/stat", "100 (bash) S 1 1 1\n")
	h.write("proc/100/environ", "SSH_CONNECTION=192.168.215.1 50000 10.0.0.2 22\x00X=y\x00")
	h.l.PPID = 300
	if who, from := h.l.Origin(); who != "vmadmin" || from != "192.168.215.1" {
		t.Fatal(who, from)
	}
	for _, a := range [][]string{{"env-set", "hello", "0", "set A"}, {"rollback", "hello", "1", "no earlier\tverified\nrelease\x1b"},
		{"deploy", "-", "rolledback"}, {"x", "../bad", "weird", ""}, {"start", "hello", "1;id"}} {
		if err := h.l.AuditWrite(ctx(), a); err != nil {
			t.Fatal(err)
		}
	}
	got := h.read("log/tando/audit.log")
	want := "1794590000\tvmadmin\t192.168.215.1\tenv-set\thello\tok\tset A\n" +
		"1794590000\tvmadmin\t192.168.215.1\trollback\thello\tfail(1)\tno earlier verified release\n" +
		"1794590000\tvmadmin\t192.168.215.1\tdeploy\t-\trolledback\t-\n" +
		"1794590000\tvmadmin\t192.168.215.1\tx\t-\tunknown\t-\n" +
		"1794590000\tvmadmin\t192.168.215.1\tstart\thello\tunknown\t-\n"
	if got != want {
		t.Fatalf("%q", got)
	}
	if fi, _ := os.Stat(h.path("log/tando/audit.log")); fi.Mode().Perm() != 0o640 {
		t.Fatal(fi.Mode())
	}
	if l := h.argvs("logger"); len(l) != 5 || l[1] != "logger -t tando-audit -- who=vmadmin from=192.168.215.1 verb=rollback app=hello result=fail(1) note=no earlier verified release" {
		t.Fatal(l)
	}
	wantErr(t, h.l.AuditWrite(ctx(), []string{"Bad Verb"}), "bad verb")
	// a timer or the boot: system from local; an activation: the requester the agent passed on
	h.l.PPID, env = 1, map[string]string{}
	if who, from := h.l.Origin(); who != "system" || from != "local" {
		t.Fatal(who, from)
	}
	env = map[string]string{"TANDO_AUDIT_WHO": "ci;rm", "TANDO_AUDIT_FROM": "10.1.1.1"}
	if who, from := h.l.Origin(); who != "unknown" || from != "10.1.1.1" {
		t.Fatal(who, from)
	}
	env = map[string]string{"SUDO_USER": "vmadmin"}
	if _, from := h.l.Origin(); from != "unknown" {
		t.Fatal("sudo without ssh:", from)
	}
	// read: newest n, one app, across the rotated files
	h.write("log/tando/audit.log.1", "1\ta\tb\tstop\thello\tok\t-\nshort\tline\n")
	o, err := h.rows(func(w *out.Writer) error { return h.l.AuditRead("hello", "3", w) })
	if err != nil || o != "audit\t1794590000\tvmadmin\t192.168.215.1\tenv-set\thello\tok\tset A\naudit\t1794590000\tvmadmin\t192.168.215.1\trollback\thello\tfail(1)\tno earlier verified release\naudit\t1794590000\tvmadmin\t192.168.215.1\tstart\thello\tunknown\t-\n" {
		t.Fatalf("%q", o)
	}
	o, _ = h.rows(func(w *out.Writer) error { return h.l.AuditRead("", "", w) })
	if strings.Count(o, "\n") != 6 || !strings.HasPrefix(o, "audit\t1\ta\tb\tstop") {
		t.Fatalf("%q", o)
	}
	_, err = h.rows(func(w *out.Writer) error { return h.l.AuditRead("../x", "", w) })
	wantErr(t, err, "invalid app name")
	_, err = h.rows(func(w *out.Writer) error { return h.l.AuditRead("", "1e3", w) })
	wantErr(t, err, "bad count")
}

func TestAuditRotation(t *testing.T) {
	h := newHost(t)
	h.write("log/tando/audit.log", strings.Repeat("x\n", auditMax/2+1))
	h.write("log/tando/audit.log.4", "oldest\n")
	h.write("log/tando/audit.log.1", "one\n")
	if err := h.l.AuditWrite(ctx(), []string{"stop", "hello", "0"}); err != nil {
		t.Fatal(err)
	}
	if h.read("log/tando/audit.log.2") != "one\n" || !strings.HasPrefix(h.read("log/tando/audit.log.1"), "x\n") ||
		!strings.HasSuffix(h.read("log/tando/audit.log"), "\tstop\thello\tok\t-\n") || strings.Count(h.read("log/tando/audit.log"), "\n") != 1 {
		t.Fatal("rotation")
	}
	if fi, _ := os.Stat(h.path("log/tando/audit.log")); fi.Mode().Perm() != 0o640 {
		t.Fatal(fi.Mode())
	}
	if auditNote(strings.Repeat("é", 200)) != strings.Repeat("é", 150) || len(auditNote(strings.Repeat("a", 400))) != 300 {
		t.Fatal("a note is cut at 300 bytes, not inside a character")
	}
}

// the package reads no environment itself: without one (tandod), origin is the system's
func TestOriginWithoutEnvironment(t *testing.T) {
	h := newHost(t)
	h.l.Getenv, h.l.PPID = nil, 0
	if who, from := h.l.Origin(); who != "system" || from != "local" {
		t.Fatal(who, from)
	}
	if l := New(h.l.Env); l.Getenv != nil || l.PPID != 0 {
		t.Fatal("New read the environment")
	}
}
