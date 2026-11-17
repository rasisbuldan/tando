package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tando/srv/internal/run"
)

func analyze(t *testing.T, root string) *Result {
	t.Helper()
	res, err := Analyze(Config{Root: filepath.Join("testdata", root), Module: "tando/srv"})
	if err != nil {
		t.Fatal(err)
	}
	return res
}

// each evasion of the no-shell rule has a package under testdata/bad/watch/ and must produce a
// finding there whose message contains want (and whose group is group)
func TestEvasionsAreCaught(t *testing.T) {
	res := analyze(t, "bad")
	tests := []struct{ dir, group, want string }{
		// os/exec under an alias, a dot import, a blank import
		{"execalias", "exec", "imports os/exec (as x)"},
		{"execdot", "exec", "imports os/exec (as .)"},
		{"execblank", "exec", "imports os/exec (as _)"},
		// os.StartProcess and syscall.Exec/ForkExec/StartProcess through an aliased import
		{"osalias", "exec", "os.StartProcess"},
		{"sysexec", "exec", "syscall.Exec"},
		{"forkexec", "exec", "syscall.ForkExec"},
		{"forkexec", "exec", "syscall.StartProcess"},
		// raw system calls: execve, an aliased constant, a bare number, a function value
		{"rawexec", "syscall", "SYS_EXECVE"},
		{"rawalias", "syscall", "SYS_EXECVEAT"},
		{"rawalias", "syscall", "not in the list for package"}, // even SYS_READLINKAT, outside gate
		{"rawnumber", "syscall", "with n"},
		{"rawnumber", "syscall", "with 59"},
		{"rawvalue", "syscall", "used as a value"},
		{"shadow", "syscall", "used as a value"},
		// concatenated literals, raw strings (several lines), -lc and -ec, paths, other shells
		{"concat", "shell", `"bash" names a shell`},
		{"concat", "shell", `"/bin/sh" names a shell`},
		{"concat", "shell", `"-c" follows the shell "bash"`},
		{"rawstring", "shell", `"-c" follows the shell "sh"`},
		{"dashc", "shell", `"-lc" follows the shell "bash5"`},
		{"dashc", "shell", `"-ec" follows the shell "dash"`},
		{"paths", "shell", `"/usr/bin/sh" names a shell`},
		{"paths", "shell", `"/bin/dash" names a shell`},
		{"paths", "shell", `"/bin/zsh" names a shell`},
		{"othershells", "shell", `"ash"`}, {"othershells", "shell", `"mksh"`}, {"othershells", "shell", `"yash"`},
		{"othershells", "shell", `"posh"`}, {"othershells", "shell", `"fish"`}, {"othershells", "shell", `"csh"`},
		{"othershells", "shell", `"tcsh"`}, {"othershells", "shell", `"rbash"`},
		// wrappers that run what they are told, and a shell behind nice, systemd-run, sudo
		{"wrappers", "program", "refusing env"},
		{"wrappers", "program", "refusing xargs"},
		{"wrappers", "program", "refusing find"},
		{"wrappers", "program", "refusing timeout"},
		{"wrappers", "shell", "refusing to start a shell (bash)"},
		{"wrappers", "shell", "refusing to start a shell (/bin/sh)"},
		{"wrappers", "shell", "refusing to start a shell (dash)"},
		// a program that is not a constant, a Cmd without field names, a wrapper called empty
		{"dynamic", "program", "is not a constant"},
		{"exported", "program", "exported Start"},
		{"assign", "program", "exported F"},
		{"unkeyed", "program", "without field names"},
		{"wrapperfunc", "program", "without a program"},
		{"wrapperfunc", "shell", `"bash" names a shell`},
		// element writes after construction, a method value of Output, systemd-run properties
		{"elemwrite", "program", "is not a constant"},
		{"elemwrite", "program", "method value of run's Output"},
		{"methodvalue", "program", "method value of run's Output"},
		{"elemwrite2", "program", "variable index"},
		{"elemwrite2", "program", "copy changes its elements"},
		{"elemwrite2", "program", "its address is taken"},
		{"elemwrite2", "program", "os.Getenv(\"Z\") is not a constant"},
		{"sysprop", "program", "property ExecStartPre is not in the list of allowed properties"},
		{"sysprop", "program", "Environment= may only be LC_ALL=C"},
		{"sysprop", "program", "option -E is not allowed"},
		{"sysprop", "program", "option --setenv=A=b is not allowed"},
		{"sysprop", "program", "has no constant name up to the ="},
		{"sysprop", "program", "option --pty is not allowed"},
		{"sysprop", "program", "ExecStartPost is not in the list"},
		{"sysprop", "program", "only `sudo -n --"},
		{"sysprop", "program", "needs a number"},
		// arguments: the forms a program may have (the reviewer's list), and unvalidated values
		{"shapes", "args", "rsync is never given -e"},
		{"shapes", "args", "rsync is never given --rsh=ssh"},
		{"shapes", "args", "rsync is never given --rsync-path=x"},
		{"shapes", "args", "sendmail is never given -C/tmp/x"},
		{"shapes", "args", "sendmail is never given -X"},
		{"shapes", "args", "du is never given --files0-from"},
		{"shapes", "args", `du is run with "-s <other`},
		{"shapes", "args", `nft is run with "-f <value-of:-f:os.Args[1]>"`},
		{"shapes", "args", "nft is never given -i"},
		{"shapes", "args", `crontab is run with "-e"`},
		{"shapes", "args", `crontab is run with "-l -u x"`},
		{"shapes", "args", `caddy is run with "run"`},
		{"shapes", "args", `caddy is run with "adapt`},
		{"shapes", "args", `python3 is run with "-c`},
		{"shapes", "args", "argument <other:os.Args[1]> of python3"},
		{"shapes", "args", `node is run with "-e 1"`},
		{"shapes", "args", "journalctl without --no-pager"},
		{"otherarg", "args", "argument <other:os.Args[1]> of systemctl is neither constant"},
		// modules, cgo-style escapes
		{"thirdparty", "deps", "golang.org/x/sys/unix"},
		{"linkname", "exec", "go:linkname"},
	}
	for _, tt := range tests {
		found := false
		for _, f := range res.Findings {
			if strings.Contains(f.Pos, "/bad/watch/"+tt.dir+"/") && f.Group == tt.group && strings.Contains(f.Msg, tt.want) {
				found = true
			}
		}
		if !found {
			t.Errorf("%s: no [%s] finding containing %q", tt.dir, tt.group, tt.want)
		}
	}
	// and every fixture package has at least one finding
	entries, _ := os.ReadDir("testdata/bad/watch")
	for _, e := range entries {
		ok := false
		for _, f := range res.Findings {
			ok = ok || strings.Contains(f.Pos, "/bad/watch/"+e.Name()+"/")
		}
		if !ok {
			t.Errorf("fixture %s has no finding", e.Name())
		}
	}
}

// what the real tree does must pass, and its programs are found through the helpers
func TestLegitimateUsesPass(t *testing.T) {
	res := analyze(t, "good")
	for _, f := range res.Findings {
		t.Errorf("unexpected finding: %s [%s] %s", f.Pos, f.Group, f.Msg)
	}
	want := `gate	getent
gate	tando-agent
gate	rsync
gate	sudo tando-gate
gate	systemctl
gate	systemd-run tando-gate
status	caddy
status	node
status	python3
status	tando-agent
watch	du
watch	nft
watch	nice tando-logs
watch	systemd-run sendmail`
	have := map[string]bool{}
	for _, l := range res.Programs {
		have[l] = true
	}
	for _, l := range strings.Split(want, "\n") {
		if !have[l] {
			t.Errorf("programs lack %q; have %q", l, res.Programs)
		}
	}
}

func TestGoModWithARequirement(t *testing.T) {
	res := analyze(t, "badmod")
	if len(res.Findings) != 1 || res.Findings[0].Group != "deps" || !strings.Contains(res.Findings[0].Msg, "require") {
		t.Errorf("findings %v", res.Findings)
	}
}

func TestLayering(t *testing.T) {
	res := analyze(t, "layers")
	got := map[string]string{}
	for _, f := range res.Findings {
		if f.Group != "layers" {
			t.Errorf("unexpected %s [%s] %s", f.Pos, f.Group, f.Msg)
			continue
		}
		got[f.Msg[:strings.Index(f.Msg, ":")]] += f.Msg + "\n"
	}
	want := map[string]string{
		"internal/a imports watch":       "internal",
		"internal/b imports daemon":      "internal",
		"watch imports logs":             "no other domain",
		"watch/sub imports status/sdbus": "no other domain",
		"logs imports daemon/proto":      "only cmd/tando-watch and cmd/tando-status",
		"status imports daemon":          "only cmd/* imports daemon",
		"metrics imports cmd/tandod":     "main package",
		"daemon imports watch/sub":       "sub-packages",
		"daemon imports status/sdbus":    "sub-packages",
		"daemon/proto imports watch":     "no domain imports",
		"gate imports daemon/proto":      "only cmd/tando-watch and cmd/tando-status",
	}
	for k, sub := range want {
		if !strings.Contains(got[k], sub) {
			t.Errorf("%s: want a finding containing %q, got %q", k, sub, got[k])
		}
		delete(got, k)
	}
	for k, v := range got {
		t.Errorf("unexpected layering finding: %s", v)
		_ = k
	}
}

func TestLayerRules(t *testing.T) {
	for _, tt := range []struct {
		from, to string
		bad      bool
	}{
		{"cmd/tandod", "daemon", false},
		{"cmd/tando-watch", "daemon/proto", false},
		{"cmd/tando-gate", "gate", false},
		{"daemon", "watch", false},
		{"daemon", "status/sdbus", true},
		{"daemon", "internal/sdbus", false},
		{"status", "internal/sdbus", false},
		{"daemon", "daemon/proto", false},
		{"watch", "internal/run", false},
		{"logs", "logs/lines", false},
		{"logs/reqlog", "logs/journal", false},
		{"logs/reqlog", "watch", true},
		{"internal/env", "internal/run", false},
		{"internal/env", "gate", true},
		{"watch", "daemon/proto", true},
		{"gate", "status", true},
		{"cmd/tandod", "cmd/tando-gate", true},
		{"tools/srvlint", "internal/run", false},
		{"tools/srvlint", "watch", true},
	} {
		if bad := layerViolation(tt.from, tt.to) != ""; bad != tt.bad {
			t.Errorf("%s -> %s: violation %v, want %v", tt.from, tt.to, bad, tt.bad)
		}
	}
}

// the checked-in programs.txt and run.Programs describe the same set
func TestProgramsFileMatchesRun(t *testing.T) {
	b, err := os.ReadFile("programs.txt")
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, l := range strings.Split(string(b), "\n") {
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		_, c, ok := strings.Cut(l, "\t")
		if !ok {
			t.Fatalf("bad line %q", l)
		}
		for _, n := range strings.Fields(c) {
			names[n] = true
		}
	}
	for _, p := range run.Programs {
		if !names[p] {
			t.Errorf("run.Programs has %q, programs.txt does not", p)
		}
		delete(names, p)
	}
	for n := range names {
		t.Errorf("programs.txt has %q, run.Programs does not", n)
	}
}

// every program of the allowlist passes the checks Exec applies, and the tool's own tables are
// consistent with the real syscall use
func TestTables(t *testing.T) {
	for _, p := range run.Programs {
		if err := run.CheckProgram(p); err != nil {
			t.Error(err)
		}
	}
	for dir, nums := range syscallNumbers {
		for n, why := range nums {
			if !strings.HasPrefix(n, "SYS_") || why == "" {
				t.Errorf("syscallNumbers[%s][%s]: needs a SYS_ name and a comment", dir, n)
			}
		}
	}
	for k, v := range dynamicPrograms {
		if err := run.CheckProgram(v); err != nil {
			t.Errorf("dynamicPrograms[%q]: %v", k, err)
		}
	}
}
