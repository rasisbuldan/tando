package gate

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
	"testing"
)

// The gate starts programs only through internal/run (argv, never a shell). On the AST, not
// lines (an alias or a split literal does not hide anything): no os/exec import under any name,
// no os.StartProcess, syscall.Exec, ForkExec or StartProcess, and raw syscalls only with the
// three numbers of fs_linux.go (fstatat, readlinkat, unlinkat), never execve.
func TestNoExecInGate(t *testing.T) {
	files, _ := filepath.Glob("*.go")
	allowed := map[string]bool{"sysFstatat": true, "syscall.SYS_READLINKAT": true, "syscall.SYS_UNLINKAT": true}
	fset := token.NewFileSet()
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, im := range af.Imports {
			// lint: allow RL15 the name of the package that must not be imported
			if p := strings.Trim(im.Path.Value, `"`); p == "os/exec" || p == "golang.org/x/sys/unix" || p == "unsafe" && f != "fs_linux.go" {
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
			switch name {
			case "os.StartProcess", "syscall.Exec", "syscall.ForkExec", "syscall.StartProcess":
				t.Errorf("%s: %s", fset.Position(call.Pos()), name)
			case "syscall.Syscall", "syscall.Syscall6", "syscall.RawSyscall", "syscall.RawSyscall6":
				num := ""
				switch a := call.Args[0].(type) {
				case *ast.Ident:
					num = a.Name
				case *ast.SelectorExpr:
					if id, ok := a.X.(*ast.Ident); ok {
						num = id.Name + "." + a.Sel.Name
					}
				}
				if !allowed[num] {
					t.Errorf("%s: %s(%s)", fset.Position(call.Pos()), name, num)
				}
			}
			return true
		})
	}
}
