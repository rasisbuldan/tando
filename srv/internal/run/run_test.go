package run

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func init() {
	// what this file's tests start (never a shell or a denied wrapper: Denied wins)
	testPrograms = []string{"echo", "cat", "ls", "sleep", "printenv", "pwd", "tando-no-such-program"}
}

func TestExec(t *testing.T) {
	ctx := context.Background()
	tests := []struct {
		name    string
		cmd     Cmd
		want    string // stdout
		wantErr string // substring of the error; "" = no error
	}{
		{name: "argv words stay words", cmd: Cmd{Argv: []string{"echo", "a b", "$(x)", ";"}}, want: "a b $(x) ;\n"},
		{name: "exact environment", cmd: Cmd{Argv: []string{"printenv"}, Env: []string{"A=1", "PATH=/usr/bin:/bin"}}, want: "A=1\nPATH=/usr/bin:/bin\n"},
		{name: "base environment", cmd: Cmd{Argv: []string{"printenv"}}, want: strings.Join(BaseEnv, "\n") + "\n"},
		{name: "stdin", cmd: Cmd{Argv: []string{"cat"}, Stdin: strings.NewReader("in")}, want: "in"},
		{name: "exit status and stderr", cmd: Cmd{Argv: []string{"ls", "/nonexistent-tando"}}, wantErr: "ls: exit status"},
		{name: "timeout", cmd: Cmd{Argv: []string{"sleep", "5"}, Timeout: 100 * time.Millisecond}, wantErr: "timed out"},
		{name: "no such program", cmd: Cmd{Argv: []string{"tando-no-such-program"}}, wantErr: "not found"},
		{name: "not in the command's PATH", cmd: Cmd{Argv: []string{"echo"}, Env: []string{"PATH=/nonexistent"}}, wantErr: "not found"},
		// lint: allow RL16 proves that a shell is refused
		{name: "a shell is refused", cmd: Cmd{Argv: []string{"sh", "-c", "true"}}, wantErr: "refusing to start a shell"},
		// lint: allow RL16 as above
		{name: "a shell by path is refused", cmd: Cmd{Argv: []string{"/bin/bash"}}, wantErr: "refusing to start a shell"},
		{name: "empty argv", cmd: Cmd{}, wantErr: "empty argv"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Exec{}.Output(ctx, tt.cmd)
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("error %v, want one containing %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != tt.want {
				t.Errorf("got %q, want %q", got, tt.want)
			}
		})
	}
}

func TestExecStreams(t *testing.T) {
	var b bytes.Buffer
	got, err := Exec{}.Output(context.Background(), Cmd{Argv: []string{"echo", "x"}, Stdout: &b})
	if err != nil || got != nil || b.String() != "x\n" {
		t.Fatalf("got %q, %v, streamed %q", got, err, b.String())
	}
}

func TestStderrIsBounded(t *testing.T) {
	var b bytes.Buffer
	w := &limitedWriter{buf: &b, max: 5}
	for range 3 {
		if n, err := w.Write([]byte("abcd")); n != 4 || err != nil {
			t.Fatalf("Write = %d, %v", n, err)
		}
	}
	if b.String() != "abcda" {
		t.Errorf("kept %q", b.String())
	}
}

func TestExecStderr(t *testing.T) {
	var e bytes.Buffer
	_, err := Exec{}.Output(context.Background(), Cmd{Argv: []string{"ls", "/nonexistent-tando"}, Stderr: &e})
	if err == nil || strings.Contains(err.Error(), "nonexistent-tando") {
		t.Fatalf("error %v: want a failure without the stderr text", err)
	}
	if !strings.Contains(e.String(), "nonexistent-tando") {
		t.Fatalf("stderr %q: want ls's message passed through", e.String())
	}
}

func TestAllowlist(t *testing.T) {
	// Programs, and only Programs, start; the names of the real tree are in it
	for _, p := range Programs {
		if CheckProgram(p) != nil && !Denied(p) {
			t.Errorf("CheckProgram(%q) = %v", p, CheckProgram(p))
		}
		if Denied(p) {
			t.Errorf("Programs has %q, which is a shell or a wrapper that is always refused", p)
		}
	}
	for i := 1; i < len(Programs); i++ {
		if Programs[i-1] >= Programs[i] {
			t.Errorf("Programs is not sorted and unique at %q", Programs[i])
		}
	}
	for _, tt := range []struct{ name, want string }{
		{"systemctl", ""},
		{"/usr/bin/rsync", ""},
		{"/opt/tando/bin/tando-agent", ""},
		{"/usr/sbin/sendmail", ""},
		{"awk", "not in the list"},
		{"python", "not in the list"},
		{"/tmp/tando-agent", "system directory"},
		{"./systemctl", "system directory"},
		{"../bin/systemctl", "system directory"},
		{"/usr/bin/../bin/rsync", "system directory"},
		{"/usr/bin//rsync", "system directory"},
		{"bin/systemctl", "system directory"},
		{"/opt/tando/bin/sh", "shell"},
		{"", "empty"},
	} {
		err := CheckProgram(tt.name)
		if tt.want == "" && err != nil || tt.want != "" && (err == nil || !strings.Contains(err.Error(), tt.want)) {
			t.Errorf("CheckProgram(%q) = %v, want %q", tt.name, err, tt.want)
		}
	}
}

// a shell is refused even when someone adds it to the list; so are the wrappers that start
// whatever their arguments say
func TestDenylistBeatsTheList(t *testing.T) {
	for _, n := range []string{"sh", "bash", "dash", "zsh", "ksh", "ash", "mksh", "yash", "posh", "fish", "csh", "tcsh", "rbash",
		"busybox", "bash5", "ksh93", "/bin/sh", "/usr/bin/dash", "/bin/bash", "/bin/zsh",
		"env", "xargs", "find", "timeout", "nohup", "setsid", "stdbuf", "chroot", "su", "runuser", "flock", "/usr/bin/env"} {
		old := testPrograms
		testPrograms = append(old[:len(old):len(old)], filepathBase(n))
		err := CheckProgram(n)
		testPrograms = old
		if err == nil || !Denied(n) {
			t.Errorf("%s: CheckProgram = %v, Denied = %v: want a refusal even when listed", n, err, Denied(n))
		}
	}
	for _, n := range []string{"nice", "sudo", "systemd-run", "systemctl", "ash2go", "fishy", "dashboard", "shred"} {
		if IsShell(n) || Denied(n) {
			t.Errorf("%s is no shell and no denied wrapper", n)
		}
	}
}

func filepathBase(p string) string { return p[strings.LastIndex(p, "/")+1:] }

func TestWrappers(t *testing.T) {
	tests := []struct {
		argv []string
		want string // "" = allowed
	}{
		{[]string{"nice", "/opt/tando/bin/tando-logs", "watch-scan"}, ""},
		{[]string{"nice", "-n", "10", "tando-logs", "x"}, ""},
		{[]string{"nice", "sh"}, "shell"},
		{[]string{"nice", "env", "sh"}, "whatever its arguments"},
		{[]string{"nice", "nice", "nice", "nice", "nice", "systemctl"}, "too deep"},
		{[]string{"nice"}, "starts no program"},
		{[]string{"nice", "--help", "x"}, "not known"},
		{[]string{"nice", "-n", "x", "systemctl"}, "needs a number"},
		{[]string{"nice", "--adjustment=x", "systemctl"}, "needs a number"},
		{[]string{"nice", "-19", "systemctl"}, ""},
		{[]string{"sudo", "-n", "--", "/opt/tando/bin/tando-gate", "root", "a", "b"}, ""},
		{[]string{"sudo", "-n", "--", "bash", "-c", "id"}, "shell"},
		{[]string{"sudo", "-u", "root", "--", "systemctl"}, "only `sudo -n --"},
		{[]string{"sudo", "-n", "-E", "--", "systemctl"}, "only `sudo -n --"},
		{[]string{"sudo", "-n", "systemctl"}, "only `sudo -n --"},
		{[]string{"sudo", "-n", "--", "env", "x"}, "whatever its arguments"},
		{[]string{"sudo", "-n", "-s", "--", "systemctl"}, "only `sudo -n --"},
		{[]string{"sudo", "-n", "--"}, "starts no program"},
		{[]string{"sudo", "-n", "--", "awk"}, "not in the list"},
		{[]string{"systemd-run", "--quiet", "--wait", "--collect", "--unit=u-1", "-p", "Description=x", "/opt/tando/bin/tando-agent", "restart", "a"}, ""},
		{[]string{"systemd-run", "--quiet", "--pipe", "-p", "Description=y", "/usr/sbin/sendmail", "-t"}, ""},
		{[]string{"systemd-run", "--pipe", "--", "tando-agent"}, ""},
		{[]string{"systemd-run", "--quiet", "/bin/sh", "-c", "x"}, "shell"},
		{[]string{"systemd-run", "--quiet", "/bin/sh", "-c", "x"}, "refusing"},
		{[]string{"systemd-run", "--pty", "systemctl"}, "not allowed"},
		{[]string{"systemd-run", "-E", "LD_PRELOAD=/tmp/x", "systemctl"}, "not allowed"},
		{[]string{"systemd-run", "--setenv=LD_PRELOAD=/tmp/x", "systemctl"}, "not allowed"},
		{[]string{"systemd-run", "--shell", "systemctl"}, "not allowed"},
		{[]string{"systemd-run", "-t", "systemctl"}, "not allowed"},
		{[]string{"systemd-run", "--uid=root", "systemctl"}, "not allowed"},
		{[]string{"systemd-run", "--property=User=root", "systemctl"}, "not allowed"},
		{[]string{"systemd-run", "-pUser=root", "systemctl"}, "not allowed"},
		{[]string{"systemd-run", "-p", "ExecStartPre=/bin/sh -c id", "tando-agent"}, "not in the list of allowed properties"},
		{[]string{"systemd-run", "-p", "ExecStopPost=/usr/bin/x", "tando-agent"}, "not in the list of allowed properties"},
		{[]string{"systemd-run", "-p", "ExecCondition=/usr/bin/x", "tando-agent"}, "not in the list of allowed properties"},
		{[]string{"systemd-run", "-p", "ExecStartPost=/usr/bin/x", "tando-agent"}, "not in the list of allowed properties"},
		{[]string{"systemd-run", "-p", "ExecStop=/usr/bin/x", "tando-agent"}, "not in the list of allowed properties"},
		{[]string{"systemd-run", "-p", "ExecReload=/usr/bin/x", "tando-agent"}, "not in the list of allowed properties"},
		{[]string{"systemd-run", "-p", "execstartpre=/usr/bin/x", "tando-agent"}, "not in the list of allowed properties"},
		{[]string{"systemd-run", "-p", "Environment=LD_PRELOAD=/tmp/x", "tando-agent"}, "Environment= may only be"},
		{[]string{"systemd-run", "-p", "Environment=LC_ALL=C", "tando-agent"}, ""},
		{[]string{"systemd-run", "-p", "Environment=LC_ALL=C LD_PRELOAD=x", "tando-agent"}, "Environment= may only be"},
		{[]string{"systemd-run", "-p", "NoName", "tando-agent"}, "no constant name"},
		{[]string{"systemd-run", "-p"}, "without a value"},
		{[]string{"systemd-run", "--unit=a b", "tando-agent"}, "bad unit name"},
		{[]string{"systemd-run", "--unit=tando-x-1", "-p", "User=tando-d-x", "-p", "MemoryMax=512M", "tando-agent"}, ""},
		{[]string{"systemd-run", "-p", "Description=y"}, "starts no program"},
		{[]string{"systemd-run", "--quiet", "xargs", "x"}, "whatever its arguments"},
		{[]string{"systemd-run", "--wait", "find", ".", "-exec", "x"}, "whatever its arguments"},
		{[]string{"systemd-run", "--wait", "timeout", "5", "x"}, "whatever its arguments"},
	}
	for _, tt := range tests {
		err := CheckArgv(tt.argv)
		if tt.want == "" && err != nil || tt.want != "" && (err == nil || !strings.Contains(err.Error(), tt.want)) {
			t.Errorf("CheckArgv(%q) = %v, want %q", tt.argv, err, tt.want)
		}
	}
}

func TestExecRefusesBeforeStarting(t *testing.T) {
	for _, argv := range [][]string{{"/bin/dash", "-c", "true"}, {"ash"}, {"env", "true"}, {"/tmp/x"}, {"nice", "sh", "-c", "true"}, {"awk", "BEGIN{system(\"true\")}"}} {
		if _, err := (Exec{}).Output(context.Background(), Cmd{Argv: argv}); err == nil || !strings.HasPrefix(err.Error(), "run:") {
			t.Errorf("Exec %q: %v, want a refusal", argv, err)
		}
	}
}

// every property the call sites use is allowed; no Exec* name is, and the list is exactly the
// names the gate and watch use (a new one is a visible change here)
func TestSystemdProperties(t *testing.T) {
	used := "Description User Group UMask Environment ProtectSystem ProtectHome ProtectProc ProtectKernelTunables " +
		"ProtectKernelModules ProtectControlGroups PrivateTmp PrivateDevices PrivateNetwork ReadWritePaths " +
		"InaccessiblePaths IPAddressDeny NoNewPrivileges RestrictSUIDSGID RestrictNamespaces LockPersonality " +
		"CapabilityBoundingSet MemoryMax TasksMax LimitFSIZE RuntimeMaxSec"
	if got := strings.Join(SystemdProperties(), " "); got != sortedFields(used) {
		t.Errorf("properties:\n got %s\nwant %s", got, sortedFields(used))
	}
	for _, p := range SystemdProperties() {
		if strings.HasPrefix(p, "Exec") {
			t.Errorf("%s: no Exec* property, ever", p)
		}
	}
}

func sortedFields(s string) string {
	f := strings.Fields(s)
	for i := range f {
		for j := i + 1; j < len(f); j++ {
			if f[j] < f[i] {
				f[i], f[j] = f[j], f[i]
			}
		}
	}
	return strings.Join(f, " ")
}

// nothing of the parent's environment reaches a child that has no Env of its own
func TestBaseEnvPassesNothingFromTheParent(t *testing.T) {
	for _, k := range []string{"FOO", "PAGER", "SYSTEMD_PAGER", "EDITOR", "VISUAL", "SUDO_EDITOR", "LD_PRELOAD", "HOME", "PATH_EXTRA", "SSH_ORIGINAL_COMMAND"} {
		t.Setenv(k, "from-parent")
	}
	got, err := Exec{}.Output(context.Background(), Cmd{Argv: []string{"printenv"}})
	if err != nil || string(got) != strings.Join(BaseEnv, "\n")+"\n" {
		t.Fatalf("child environment %q, %v: want exactly BaseEnv", got, err)
	}
	for _, kv := range BaseEnv {
		if strings.HasPrefix(kv, "LD_") || strings.Contains(kv, "PAGER") || strings.Contains(kv, "EDITOR") {
			t.Errorf("BaseEnv has %s", kv)
		}
	}
}

// an environment a caller builds loses what loads or starts other programs
func TestEnvIsScrubbed(t *testing.T) {
	env := []string{"A=1", "LD_PRELOAD=/tmp/x", "PAGER=sh", "SYSTEMD_PAGER=sh", "EDITOR=sh", "VISUAL=sh", "SUDO_EDITOR=sh", "DYLD_X=1", "PATH=/usr/bin:/bin"}
	got, err := Exec{}.Output(context.Background(), Cmd{Argv: []string{"printenv"}, Env: env})
	if err != nil || string(got) != "A=1\nPATH=/usr/bin:/bin\n" {
		t.Fatalf("got %q, %v", got, err)
	}
}

// a command runs in "/", not in the caller's directory (a venv.py there would be imported by
// python3 when root asks for the tool versions), unless the caller names a directory
func TestWorkingDirectory(t *testing.T) {
	d := t.TempDir()
	t.Chdir(d)
	got, err := Exec{}.Output(context.Background(), Cmd{Argv: []string{"pwd"}})
	if err != nil || string(got) != "/\n" {
		t.Fatalf("pwd = %q, %v: want /", got, err)
	}
	other := t.TempDir()
	got, err = Exec{}.Output(context.Background(), Cmd{Argv: []string{"pwd"}, Dir: other})
	if err != nil || filepath.Base(strings.TrimSpace(string(got))) != filepath.Base(other) {
		t.Fatalf("pwd = %q, %v: want %s", got, err, other)
	}
}

func TestPythonDoesNotImportFromTheWorkingDirectory(t *testing.T) {
	py := ""
	for _, d := range []string{"/usr/bin", "/usr/local/bin", "/bin"} {
		if fi, err := os.Stat(d + "/python3"); err == nil && fi.Mode().IsRegular() {
			py = d + "/python3"
			break
		}
	}
	if py == "" {
		t.Skip("no python3 in a system directory")
	}
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "venv.py"), []byte("raise SystemExit('imported from cwd')\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(d)
	got, err := Exec{}.Output(context.Background(), Cmd{Argv: []string{py, "-I", "-c", "import venv; print(venv.__file__)"}})
	if err != nil || strings.HasPrefix(string(got), d) || strings.Contains(string(got), "imported from cwd") {
		t.Fatalf("python3 imported %q: %v", got, err)
	}
	// the premise: in that directory, without -I, python3 does import it
	_, err = Exec{}.Output(context.Background(), Cmd{Argv: []string{py, "-c", "import venv"}, Dir: d})
	if err == nil {
		t.Error("the test's venv.py is not imported even from its own directory: the test proves nothing")
	}
	if _, err = (Exec{}).Output(context.Background(), Cmd{Argv: []string{py, "-I", "-c", "import venv"}, Dir: d}); err != nil {
		t.Errorf("python3 -I imported from the working directory: %v", err)
	}
}
