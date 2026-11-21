package studio

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The studio starts no program and listens on no network port. On the syntax trees of every
// non-test file of the studio's packages and its main: no os/exec (under any name), no
// tando/srv/internal/run, no os.StartProcess / syscall.Exec / ForkExec / StartProcess, no raw
// syscall, and net.Listen / ListenPacket only with "unix". One exception, the service's front
// (docs/STUDIO.md): cmd/tando-studio/spawn.go may import os/exec for one call only,
// exec.Command(sp.Bin, "serve", ...), its own binary as a helper.
func TestNoExecNoNetworkListener(t *testing.T) {
	var files []string
	for _, g := range []string{"*.go", "pgwire/*.go", "sqlsplit/*.go", "../cmd/tando-studio/*.go"} {
		m, _ := filepath.Glob(g)
		files = append(files, m...)
	}
	if len(files) < 10 {
		t.Fatalf("only %d files found", len(files))
	}
	fset := token.NewFileSet()
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		spawn := filepath.Base(f) == "spawn.go" && strings.Contains(f, "cmd/tando-studio")
		execs := 0
		for _, im := range af.Imports {
			p, _ := strconv.Unquote(im.Path.Value)
			// lint: allow RL15 the one front file that may import os/exec
			if spawn && p == "os/exec" && im.Name == nil {
				continue
			}
			// lint: allow RL15 the names of the packages that must not be imported
			if p == "os/exec" || p == "tando/srv/internal/run" || p == "plugin" || p == "unsafe" || p == "golang.org/x/sys/unix" {
				t.Errorf("%s imports %s", f, p)
			}
		}
		ast.Inspect(af, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			x, _ := sel.X.(*ast.Ident)
			if x == nil {
				return true
			}
			name := x.Name + "." + sel.Sel.Name
			if spawn && x.Name == "exec" {
				execs++
				arg0, _ := call.Args[0].(*ast.SelectorExpr)
				arg1, _ := call.Args[1].(*ast.BasicLit)
				if name != "exec.Command" || arg0 == nil || arg0.Sel.Name != "Bin" || litValue(arg1, arg1 != nil) != `"serve"` {
					t.Errorf("%s: %s: the front starts only its own binary as serve", fset.Position(call.Pos()), name)
				}
			}
			switch name {
			case "os.StartProcess", "syscall.Exec", "syscall.ForkExec", "syscall.StartProcess",
				"syscall.Syscall", "syscall.Syscall6", "syscall.RawSyscall", "syscall.RawSyscall6":
				t.Errorf("%s: %s", fset.Position(call.Pos()), name)
			case "net.Listen", "net.ListenUnix", "net.ListenPacket", "net.ListenTCP", "net.ListenUDP", "net.ListenIP", "http.ListenAndServe", "http.ListenAndServeTLS":
				lit, ok := call.Args[0].(*ast.BasicLit)
				if v, _ := strconv.Unquote(litValue(lit, ok)); v != "unix" {
					t.Errorf("%s: %s(%s): only a unix socket", fset.Position(call.Pos()), name, litValue(lit, ok))
				}
			}
			return true
		})
		if spawn && execs != 1 {
			t.Errorf("%s: %d calls of package exec, want exactly one", f, execs)
		}
	}
}

func litValue(l *ast.BasicLit, ok bool) string {
	if !ok {
		return "<not a constant>"
	}
	return l.Value
}
