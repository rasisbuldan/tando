package main

import (
	"fmt"
	"go/ast"
	"go/constant"
	"go/parser"
	"go/printer"
	"go/token"
	"go/types"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"tando/srv/internal/run"
)

// Config says what to read. Module is the module path ("" reads it from Root/go.mod).
type Config struct {
	Root   string
	Module string
}

// Finding is one violation (or, in a test file, one warning). Group is the kind: exec, syscall,
// shell, program, deps (the no-shell rules) or layers.
type Finding struct {
	Pos   string
	Group string
	Msg   string
}

// Result is what Analyze found.
type Result struct {
	Findings  []Finding
	Warnings  []Finding      // the same checks on _test.go files: tests may do what programs may not
	Programs  []string       // "package TAB program" (a wrapper's program follows it: "nice tando-logs"), sorted
	Args      []string       // the -args table (args.go), sorted
	Counts    map[string]int // how many argument positions of each kind
	NPackages int
}

// syscallNumbers: raw system calls are allowed only with these numbers, per package (the
// directory under srv/). Everything else, execve above all, is refused; the first argument must
// be syscall.SYS_X or a constant of the package whose value is syscall.SYS_X.
var syscallNumbers = map[string]map[string]string{
	"gate": {
		"SYS_FSTATAT":    "fstatat(AT_SYMLINK_NOFOLLOW) on arm64 (fs_linux_arm64.go): the walk looks at an entry without following it",
		"SYS_NEWFSTATAT": "the same on amd64 (fs_linux_amd64.go; there fstatat is called newfstatat)",
		"SYS_READLINKAT": "readlinkat relative to the directory descriptor of the walk (fs_linux.go)",
		"SYS_UNLINKAT":   "unlinkat relative to the directory descriptor of the walk (fs_linux.go)",
	},
	"logs": {
		"SYS_FSTATAT":    "fstatat on arm64 (stat_linux_arm64.go): the request index reads a file's identity without following links",
		"SYS_NEWFSTATAT": "the same on amd64 (stat_linux_amd64.go)",
	},
}

// dynamicPrograms: program names that are not constants because they come from a field of a
// configuration struct (the paths the tando programs have under /opt/tando/bin; they are set in
// one place, gate.go). Key: the package, the expression as written. The program they name is
// listed in programs.txt like any other, and run.Exec checks the real value at run time.
var dynamicPrograms = map[string]string{
	"gate g.P.Agent": "tando-agent", // Paths.Agent = <root>/bin/tando-agent (gate.go)
	"gate g.P.Gate":  "tando-gate",  // Paths.Gate = <root>/bin/tando-gate (gate.go)
	"watch s.bin":    "tando-logs",  // execScanner.bin = <root>/bin/tando-logs, the one-shot's log scan (pretick.go)
}

// pathResolvers: functions that return the path of an installed program from its name: the
// name (this argument) is what is listed.
var pathResolvers = map[string]int{
	"bin":      0, // Watch.bin, Collector.bin: <root>/bin/<name>
	"which":    0, // watch's which: <name> found in the PATH of cmdEnv
	"lookTool": 0, // status's lookTool: <name> found in SecurePath
}

// layering: the layer of a package is the first element of its directory under srv/.
var domains = map[string]bool{"watch": true, "logs": true, "metrics": true, "gate": true, "status": true, "studio": true, "live": true}

// forbiddenImports are refused everywhere outside the tests, whatever the name they get.
var forbiddenImports = map[string]string{
	"C":            "cgo",
	"plugin":       "plugins load code",
	"net/http/cgi": "runs programs",
}

type pkg struct {
	dir   string // relative to the root, slash-separated; "." for the root
	name  string
	files []*ast.File
	info  *types.Info
	fset  *token.FileSet

	res     *Result
	module  string
	runPath string

	defs   map[types.Object][]def // local and package variables: what is assigned to them
	params map[types.Object]param // function parameters
	calls  map[string][]*ast.CallExpr
	consts map[string][]ast.Expr // package-level const name -> its value expressions
	memo   map[string][]chain    // wrapper functions already followed
	uses   map[string]bool       // programs run here (non-test)

	writes         map[types.Object][]write  // writes to the elements of a slice variable after it was built
	argvElemWrites []write                   // c.Argv[i] = x
	ranges         map[types.Object]ast.Expr // the range expression of a range variable
	mute           bool                      // report nothing (the -args pass walks the same expressions again)
}

// write is a change to a slice variable's elements after it was built: a[i] = rhs (rhs nil when
// it is not a plain assignment), or copy(a, ...), &a, slices.X(a), sort.X(a) (index and rhs nil).
type write struct {
	node  ast.Node
	index ast.Expr
	rhs   ast.Expr
	other string // what the lint cannot follow ("" for a plain a[i] = rhs)
}

type def struct {
	rhs   ast.Expr
	index int // which value of a multi-value call
	n     int // how many names on the left
}

type param struct {
	fn       *ast.FuncDecl
	index    int
	variadic bool
}

// Analyze reads every .go file under cfg.Root and checks it.
func Analyze(cfg Config) (*Result, error) {
	module := cfg.Module
	if module == "" {
		b, err := os.ReadFile(filepath.Join(cfg.Root, "go.mod"))
		if err != nil {
			return nil, err
		}
		for l := range strings.SplitSeq(string(b), "\n") {
			if m, ok := strings.CutPrefix(strings.TrimSpace(l), "module "); ok {
				module = strings.TrimSpace(m)
			}
		}
		if module == "" {
			return nil, fmt.Errorf("no module line in %s/go.mod", cfg.Root)
		}
	}
	res := &Result{}
	checkGoMod(cfg.Root, res)

	dirs := map[string][]string{}
	err := filepath.WalkDir(cfg.Root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		n := d.Name()
		if d.IsDir() && p != cfg.Root && (n == "testdata" || n == "vendor" || strings.HasPrefix(n, ".") || strings.HasPrefix(n, "_")) {
			return filepath.SkipDir
		}
		if !d.IsDir() && strings.HasSuffix(n, ".go") {
			rel, _ := filepath.Rel(cfg.Root, filepath.Dir(p))
			rel = filepath.ToSlash(rel)
			dirs[rel] = append(dirs[rel], p)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	var names []string
	for d := range dirs {
		names = append(names, d)
	}
	sort.Strings(names)
	progs := map[string]bool{}
	argSet := map[string]bool{}
	res.Counts = map[string]int{}
	for _, d := range names {
		p, err := load(cfg.Root, d, dirs[d], module, res)
		if err != nil {
			return nil, err
		}
		res.NPackages++
		p.check()
		p.argTable(argSet, res.Counts)
		for u := range p.uses {
			progs[u] = true
		}
	}
	for u := range progs {
		res.Programs = append(res.Programs, u)
	}
	sort.Strings(res.Programs)
	for l := range argSet {
		res.Args = append(res.Args, l)
	}
	sort.Strings(res.Args)
	return res, nil
}

// checkGoMod: standard library only means no requirement, no replacement, no vendor directory.
func checkGoMod(root string, res *Result) {
	b, err := os.ReadFile(filepath.Join(root, "go.mod"))
	if err != nil {
		res.add(false, filepath.Join(root, "go.mod"), "deps", err.Error())
		return
	}
	for i, l := range strings.Split(string(b), "\n") {
		f := strings.Fields(l)
		if len(f) > 0 && (f[0] == "require" || f[0] == "replace" || f[0] == "godebug" || f[0] == "tool") {
			res.add(false, fmt.Sprintf("%s:%d", filepath.Join(root, "go.mod"), i+1), "deps", "go.mod has a "+f[0]+": the standard library only, no modules")
		}
	}
	for _, f := range []string{"go.sum", "vendor"} {
		if _, err := os.Stat(filepath.Join(root, f)); err == nil {
			res.add(false, filepath.Join(root, f), "deps", f+" exists: the standard library only, no modules")
		}
	}
}

func (r *Result) add(test bool, pos, group, msg string) {
	f := Finding{Pos: pos, Group: group, Msg: msg}
	for _, o := range append(r.Findings[:len(r.Findings):len(r.Findings)], r.Warnings...) {
		if o == f {
			return
		}
	}
	if test {
		r.Warnings = append(r.Warnings, f)
	} else {
		r.Findings = append(r.Findings, f)
	}
}

// fakeImporter gives every import a package of the right path and name and nothing in it: the
// checker then resolves each name to its import (types.PkgName) and folds constants, which is all
// the lint needs, without compiling anything or reading the standard library.
type fakeImporter map[string]*types.Package

func (f fakeImporter) Import(p string) (*types.Package, error) {
	if pk, ok := f[p]; ok {
		return pk, nil
	}
	name := path.Base(p)
	if m, _ := regexp.MatchString(`^v[0-9]+$`, name); m && strings.Contains(p, "/") {
		name = path.Base(path.Dir(p))
	}
	pk := types.NewPackage(p, strings.NewReplacer("-", "_", ".", "_").Replace(name))
	pk.MarkComplete()
	f[p] = pk
	return pk, nil
}

func load(root, dir string, files []string, module string, res *Result) (*pkg, error) {
	sort.Strings(files)
	p := &pkg{dir: dir, res: res, module: module, runPath: module + "/internal/run", fset: token.NewFileSet(),
		defs: map[types.Object][]def{}, params: map[types.Object]param{}, calls: map[string][]*ast.CallExpr{},
		consts: map[string][]ast.Expr{}, memo: map[string][]chain{}, writes: map[types.Object][]write{}, ranges: map[types.Object]ast.Expr{}, uses: map[string]bool{}}
	for _, f := range files {
		af, err := parser.ParseFile(p.fset, f, nil, parser.ParseComments)
		if err != nil {
			return nil, err
		}
		p.files = append(p.files, af)
		if p.name == "" || !strings.HasSuffix(af.Name.Name, "_test") {
			p.name = af.Name.Name
		}
	}
	p.info = &types.Info{Types: map[ast.Expr]types.TypeAndValue{}, Defs: map[*ast.Ident]types.Object{}, Uses: map[*ast.Ident]types.Object{}}
	// the files of one directory are one package (plus its external tests): checked together;
	// errors (duplicate names of the per-CPU files, the empty imports) do not matter here
	conf := types.Config{Importer: fakeImporter{}, Error: func(error) {}, FakeImportC: true}
	conf.Check(path.Join(module, dir), p.fset, p.files, p.info)
	p.index()
	return p, nil
}

func (p *pkg) isTest(n ast.Node) bool {
	return strings.HasSuffix(p.fset.Position(n.Pos()).Filename, "_test.go")
}

func (p *pkg) pos(n ast.Node) string {
	ps := p.fset.Position(n.Pos())
	return fmt.Sprintf("%s:%d:%d", filepath.ToSlash(ps.Filename), ps.Line, ps.Column)
}

func (p *pkg) report(n ast.Node, group, format string, a ...any) {
	if p.mute {
		return
	}
	p.res.add(p.isTest(n), p.pos(n), group, fmt.Sprintf(format, a...))
}

func (p *pkg) expr(e ast.Node) string {
	var b strings.Builder
	printer.Fprint(&b, token.NewFileSet(), e)
	return b.String()
}

// index records, for every variable, what is assigned to it; for every function parameter its
// place; the calls by callee name; the package-level constants.
func (p *pkg) index() {
	for _, f := range p.files {
		ast.Inspect(f, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.FuncDecl:
				i := 0
				for _, fld := range n.Type.Params.List {
					_, variadic := fld.Type.(*ast.Ellipsis)
					if len(fld.Names) == 0 {
						i++
					}
					for _, id := range fld.Names {
						if o := p.info.Defs[id]; o != nil {
							p.params[o] = param{n, i, variadic}
						}
						i++
					}
				}
			case *ast.RangeStmt:
				if id, ok := n.Value.(*ast.Ident); ok {
					if o := p.info.Defs[id]; o != nil {
						p.ranges[o] = n.X
					}
				}
			case *ast.UnaryExpr:
				if id, ok := ast.Unparen(n.X).(*ast.Ident); ok && n.Op == token.AND {
					if o := p.info.Uses[id]; o != nil {
						p.writes[o] = append(p.writes[o], write{node: n, other: "its address is taken"})
					}
				}
			case *ast.IncDecStmt:
				p.noteElemWrite(n, n.X, nil)
			case *ast.AssignStmt:
				for i, l := range n.Lhs {
					if ix, ok := ast.Unparen(l).(*ast.IndexExpr); ok {
						var rhs ast.Expr
						if n.Tok == token.ASSIGN && len(n.Rhs) == len(n.Lhs) {
							rhs = n.Rhs[i]
						}
						p.noteElemWrite(n, ix, rhs)
						continue
					}
					id, ok := l.(*ast.Ident)
					if !ok {
						continue
					}
					o := p.info.Defs[id]
					if o == nil {
						o = p.info.Uses[id]
					}
					if o == nil {
						continue
					}
					if len(n.Rhs) == len(n.Lhs) {
						p.defs[o] = append(p.defs[o], def{n.Rhs[i], 0, 1})
					} else if len(n.Rhs) == 1 {
						p.defs[o] = append(p.defs[o], def{n.Rhs[0], i, len(n.Lhs)})
					}
				}
			case *ast.ValueSpec:
				for i, id := range n.Names {
					if o := p.info.Defs[id]; o != nil {
						if len(n.Values) == len(n.Names) {
							p.defs[o] = append(p.defs[o], def{n.Values[i], 0, 1})
						} else if len(n.Values) == 1 {
							p.defs[o] = append(p.defs[o], def{n.Values[0], i, len(n.Names)})
						}
					}
					if len(n.Values) == len(n.Names) {
						p.consts[id.Name] = append(p.consts[id.Name], n.Values[i])
					}
				}
			case *ast.CallExpr:
				p.noteCallWrites(n)
				switch fn := n.Fun.(type) {
				case *ast.Ident:
					p.calls[fn.Name] = append(p.calls[fn.Name], n)
				case *ast.SelectorExpr:
					p.calls[fn.Sel.Name] = append(p.calls[fn.Sel.Name], n)
				}
			}
			return true
		})
	}
}

// noteElemWrite records x[i] = rhs (x an identifier) and a.Argv[i] = rhs on the Argv of a Cmd.
func (p *pkg) noteElemWrite(n ast.Node, x ast.Expr, rhs ast.Expr) {
	ix, ok := ast.Unparen(x).(*ast.IndexExpr)
	if !ok {
		return
	}
	switch b := ast.Unparen(ix.X).(type) {
	case *ast.Ident:
		if o := p.info.Uses[b]; o != nil {
			p.writes[o] = append(p.writes[o], write{n, ix.Index, rhs, ""})
		}
	case *ast.SelectorExpr:
		if b.Sel.Name == "Argv" {
			p.argvElemWrites = append(p.argvElemWrites, write{n, ix.Index, rhs, ""})
		}
	}
}

// noteCallWrites: copy(a, ...), slices.F(a, ...), sort.F(a) change a's elements in ways the lint
// does not follow.
func (p *pkg) noteCallWrites(c *ast.CallExpr) {
	name := ""
	if id, ok := c.Fun.(*ast.Ident); ok && id.Name == "copy" {
		name = "copy"
	} else if ip, n := p.qualified(c.Fun); ip == "slices" || ip == "sort" {
		name = ip + "." + n
	}
	if name == "" || len(c.Args) == 0 {
		return
	}
	if id, ok := ast.Unparen(c.Args[0]).(*ast.Ident); ok {
		if o := p.info.Uses[id]; o != nil {
			p.writes[o] = append(p.writes[o], write{node: c, other: name + " changes its elements"})
		}
	}
}

// pkgOf returns the import path that the identifier x names, "" when it is not a package name
// (a variable called os is not the package).
func (p *pkg) pkgOf(x ast.Expr) string {
	id, ok := x.(*ast.Ident)
	if !ok {
		return ""
	}
	if pn, ok := p.info.Uses[id].(*types.PkgName); ok {
		return pn.Imported().Path()
	}
	return ""
}

// qualified returns the import path and member of pkgname.Member, else "", "".
func (p *pkg) qualified(e ast.Expr) (string, string) {
	if s, ok := e.(*ast.SelectorExpr); ok {
		if ip := p.pkgOf(s.X); ip != "" {
			return ip, s.Sel.Name
		}
	}
	return "", ""
}

func (p *pkg) check() {
	isRun := p.dir == "internal/run"
	p.checkImports(isRun)
	p.checkLayers()
	callFuns := map[ast.Expr]*ast.CallExpr{}
	for _, f := range p.files {
		ast.Inspect(f, func(n ast.Node) bool {
			if c, ok := n.(*ast.CallExpr); ok {
				callFuns[c.Fun] = c
			}
			return true
		})
	}
	for _, w := range p.argvElemWrites {
		if isRun {
			break
		}
		if tv := p.info.Types[w.index]; tv.Value == nil || tv.Value.String() == "0" {
			r := &resolver{p: p, seen: map[ast.Node]bool{}}
			if w.rhs == nil || tv.Value == nil {
				p.report(w.node, "program", "an element of a Cmd's Argv is written in a way the program name may change")
			} else {
				for _, n := range r.prog(w.rhs, w.node) {
					p.record(w.node, chain{n})
				}
			}
		}
	}
	for _, f := range p.files {
		for _, cg := range f.Comments {
			for _, c := range cg.List {
				if strings.HasPrefix(c.Text, "//go:linkname") {
					p.report(c, "exec", "go:linkname reaches into the runtime and the os package's internals")
				}
			}
		}
		ast.Inspect(f, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.SelectorExpr:
				p.checkSelector(n, callFuns[n])
				if n.Sel.Name == "Output" && callFuns[n] == nil && !isRun {
					p.report(n, "program", "%s is a method value of run's Output: call it directly, so that the Cmd it gets is seen", p.expr(n))
				}
			case *ast.CompositeLit:
				if !isRun {
					p.checkCmdLit(n)
				}
			case *ast.AssignStmt:
				if !isRun {
					p.checkArgvAssign(n)
				}
			}
			return true
		})
	}
}

// checkImports: os/exec only in internal/run, no third-party module, no cgo, no plugins; no dot
// import of a package this lint looks into by name.
func (p *pkg) checkImports(isRun bool) {
	for _, f := range p.files {
		for _, im := range f.Imports {
			ip := strings.Trim(im.Path.Value, "`\"")
			test := p.isTest(im)
			dot := im.Name != nil && im.Name.Name == "."
			switch {
			case ip == "os/exec" && !(isRun && !test):
				p.report(im, "exec", "imports os/exec (as %s): only %s/internal/run may; start programs with run.Cmd", importName(im), p.module)
			case forbiddenImports[ip] != "":
				p.report(im, "exec", "imports %s (%s)", ip, forbiddenImports[ip])
			case dot && (ip == "os" || ip == "syscall" || ip == "os/exec" || ip == p.runPath):
				p.report(im, "exec", "dot import of %s hides what is called from it", ip)
			case !stdlib(ip) && ip != p.module && !strings.HasPrefix(ip, p.module+"/"):
				p.report(im, "deps", "imports %s: the standard library only (no golang.org/x/sys either)", ip)
			}
		}
	}
}

func importName(im *ast.ImportSpec) string {
	if im.Name != nil {
		return im.Name.Name
	}
	return "its own name"
}

func stdlib(ip string) bool {
	first, _, _ := strings.Cut(ip, "/")
	return !strings.Contains(first, ".") && ip != "C"
}

var execMembers = map[string]bool{"StartProcess": true, "Exec": true, "ForkExec": true}

// checkSelector: os.StartProcess, syscall.Exec/ForkExec/StartProcess (called or not, under any
// import name), raw system calls with a number that is not in the package's list.
func (p *pkg) checkSelector(s *ast.SelectorExpr, call *ast.CallExpr) {
	ip, name := p.qualified(s)
	switch {
	case ip == "os" && name == "StartProcess", ip == "syscall" && execMembers[name]:
		p.report(s, "exec", "%s.%s starts a program (through the import %s): use run.Cmd", path.Base(ip), name, ip)
	case ip == "syscall" && (strings.HasPrefix(name, "Syscall") || strings.HasPrefix(name, "RawSyscall")):
		if call == nil || len(call.Args) == 0 {
			p.report(s, "syscall", "syscall.%s used as a value: it must be called, with a number from the list of this package", name)
			return
		}
		num, ok := p.syscallNumber(call.Args[0])
		allow := syscallNumbers[p.dir]
		switch {
		case !ok:
			p.report(s, "syscall", "syscall.%s with %s: the number must be syscall.SYS_X (or a constant of this package that is)", name, p.expr(call.Args[0]))
		case allow[num] == "":
			p.report(s, "syscall", "syscall.%s(%s): this number is not in the list for package %s (tools/srvlint/lint.go syscallNumbers)", name, num, p.dir)
		}
	}
}

// syscallNumber names the syscall.SYS_X that e is.
func (p *pkg) syscallNumber(e ast.Expr) (string, bool) {
	e = ast.Unparen(e)
	if ip, n := p.qualified(e); ip == "syscall" && strings.HasPrefix(n, "SYS_") {
		return n, true
	}
	if id, ok := e.(*ast.Ident); ok {
		if o := p.info.Uses[id]; o != nil {
			if _, isConst := o.(*types.Const); !isConst {
				return "", false
			}
		}
		vals := p.consts[id.Name]
		if len(vals) == 0 {
			return "", false
		}
		first := ""
		for _, v := range vals { // one per CPU in the per-CPU files: all must be allowed
			n, ok := p.syscallNumber(v)
			if !ok {
				return "", false
			}
			if bad := syscallNumbers[p.dir][n] == ""; bad || first == "" {
				first = n
				if bad {
					return n, true
				}
			}
		}
		return first, true
	}
	return "", false
}

// isRunCmd: the type expression names run.Cmd (in package run itself: Cmd).
func (p *pkg) isRunCmd(t ast.Expr) bool {
	if ip, n := p.qualified(t); ip == p.runPath && n == "Cmd" {
		return true
	}
	id, ok := t.(*ast.Ident)
	return ok && id.Name == "Cmd" && p.dir == "internal/run"
}

func (p *pkg) checkCmdLit(l *ast.CompositeLit) {
	if l.Type == nil || !p.isRunCmd(l.Type) {
		return
	}
	p.scanShellConsts(l)
	for _, e := range l.Elts {
		kv, ok := e.(*ast.KeyValueExpr)
		if !ok {
			p.report(l, "program", "run.Cmd literal without field names")
			return
		}
		if k, _ := kv.Key.(*ast.Ident); k != nil && k.Name == "Argv" {
			p.argvSite(kv.Value, l)
		}
	}
}

func (p *pkg) checkArgvAssign(a *ast.AssignStmt) {
	for i, l := range a.Lhs {
		if s, ok := l.(*ast.SelectorExpr); ok && s.Sel.Name == "Argv" && len(a.Rhs) == len(a.Lhs) {
			p.scanShellConsts(a.Rhs[i])
			p.argvSite(a.Rhs[i], a)
		}
	}
}

// argvSite resolves the program of one argv expression and records it.
func (p *pkg) argvSite(e ast.Expr, site ast.Node) {
	r := &resolver{p: p, seen: map[ast.Node]bool{}}
	for _, chain := range r.argv(e, site) {
		p.record(site, chain)
	}
}

func (p *pkg) record(site ast.Node, chain []string) {
	for _, n := range chain {
		if p.isTest(site) && !run.IsShell(n) {
			continue // tests run fake programs through fake runners; only a shell is worth a word
		}
		if err := run.CheckProgram(n); err != nil {
			g := "program"
			if run.IsShell(n) {
				g = "shell"
			}
			p.report(site, g, "%v", err)
		}
	}
	if p.isTest(site) {
		return
	}
	names := make([]string, len(chain))
	for i, n := range chain {
		names[i] = filepath.Base(n)
	}
	p.uses[p.dir+"\t"+strings.Join(names, " ")] = true
}

var dashC = regexp.MustCompile(`^-[A-Za-z]*c[A-Za-z]*$`)

// scanShellConsts: in the arguments of a call into the run API, no string constant (concatenations
// folded: "ba"+"sh", "/bin/"+"sh") may be a shell or have a shell as basename, and no argument
// that follows a shell's name may be -c, -lc, -ec ...
func (p *pkg) scanShellConsts(n ast.Node) {
	ast.Inspect(n, func(x ast.Node) bool {
		switch x := x.(type) {
		case *ast.CompositeLit:
			// consecutive constant elements: a shell name, then a command-string flag
			for i := 0; i+1 < len(x.Elts); i++ {
				if a, ok := p.constString(x.Elts[i]); ok && run.IsShell(a) {
					if b, ok := p.constString(x.Elts[i+1]); ok && dashC.MatchString(b) {
						p.report(x.Elts[i+1], "shell", "%q follows the shell %q: a command string", b, a)
					}
				}
			}
		}
		if e, ok := x.(ast.Expr); ok {
			if v, ok := p.constString(e); ok && v != "" && run.IsShell(v) {
				if _, isBin := e.(*ast.BinaryExpr); isBin || isLeaf(e) {
					p.report(e, "shell", "the constant %q names a shell: no shell, ever", v)
				}
			}
		}
		return true
	})
}

func isLeaf(e ast.Expr) bool {
	switch e.(type) {
	case *ast.BasicLit, *ast.Ident, *ast.SelectorExpr, *ast.ParenExpr:
		return true
	}
	return false
}

// constString folds e (literals, concatenations, constants of the package) to its value.
func (p *pkg) constString(e ast.Expr) (string, bool) {
	if tv, ok := p.info.Types[e]; ok && tv.Value != nil && tv.Value.Kind() == constant.String {
		return constant.StringVal(tv.Value), true
	}
	return "", false
}

// resolver finds what program an argv starts, following variables, append, wrapper functions
// and path resolvers.
type resolver struct {
	p    *pkg
	seen map[ast.Node]bool
}

type chain = []string

// argv: the programs (each with the programs it starts) that an expression of type []string, or
// the elements of a literal list, starts.
func (r *resolver) argv(e ast.Expr, site ast.Node) []chain {
	p := r.p
	e = ast.Unparen(e)
	if r.seen[e] {
		return nil
	}
	r.seen[e] = true
	switch e := e.(type) {
	case *ast.CompositeLit:
		return r.elts(e.Elts, site)
	case *ast.CallExpr:
		if id, ok := e.Fun.(*ast.Ident); ok && id.Name == "append" && len(e.Args) > 0 {
			return r.argv(e.Args[0], site)
		}
	case *ast.SelectorExpr:
		if e.Sel.Name == "Argv" {
			return nil // the field of a Cmd that was assigned elsewhere
		}
	case *ast.Ident:
		o := p.info.Uses[e]
		if o == nil {
			o = p.info.Defs[e]
		}
		if pr, ok := p.params[o]; ok {
			return r.wrapper(pr, site, "argv")
		}
		if ds := p.defs[o]; len(ds) > 0 {
			var out []chain
			out = append(out, r.writtenPrograms(o, site)...)
			for _, d := range ds {
				if d.n == 1 {
					out = append(out, r.argv(d.rhs, site)...)
				} else {
					p.report(site, "program", "cannot follow %s (a multi-value assignment): build argv in one place", e.Name)
				}
			}
			return out
		}
	}
	p.report(site, "program", "cannot see the program of %s: build argv from a literal, append or a wrapper whose callers pass constants", p.expr(e))
	return nil
}

// writtenPrograms: what later writes to the elements of the slice variable o can make the
// program: a constant or resolvable value written to element 0 adds that program; a write the
// lint cannot follow (a variable index, copy, &a, slices.X) makes it "dynamic": a finding.
func (r *resolver) writtenPrograms(o types.Object, site ast.Node) []chain {
	var out []chain
	for _, w := range r.p.writes[o] {
		switch {
		case w.other != "":
			r.p.report(site, "program", "the argv is changed after it was built (%s at %s): the program name may be dynamic", w.other, r.p.pos(w.node))
		default:
			tv, isConst := r.p.info.Types[w.index]
			if !isConst || tv.Value == nil {
				r.p.report(site, "program", "the argv is written at a variable index (%s): the program name may be dynamic", r.p.pos(w.node))
			} else if tv.Value.String() == "0" {
				if w.rhs == nil {
					r.p.report(site, "program", "element 0 of the argv is written with an operation the lint cannot follow (%s)", r.p.pos(w.node))
					continue
				}
				for _, n := range r.prog(w.rhs, site) {
					out = append(out, chain{n})
				}
			}
		}
	}
	return out
}

// elts: argv given as its elements (a literal, or the arguments of a call to a variadic wrapper).
func (r *resolver) elts(es []ast.Expr, site ast.Node) []chain {
	if len(es) == 0 {
		r.p.report(site, "program", "empty argv")
		return nil
	}
	var out []chain
	for _, name := range r.prog(es[0], site) {
		c := chain{name}
		w := filepath.Base(name)
		if !contains(run.Wrappers(), w) {
			out = append(out, c)
			continue
		}
		inner, err := r.innerElts(w, es[1:])
		if err != nil {
			r.p.report(site, "program", "%s: %v (the options and the program must be in the literal list)", name, err)
			out = append(out, c)
			continue
		}
		for _, ic := range r.elts(inner, site) {
			out = append(out, append(append(chain{}, c...), ic...))
		}
	}
	return out
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

// innerElts finds the elements that start the wrapper's program: run.Inner (the rules Exec
// applies: the options each wrapper knows, the property names systemd-run may set) is run over
// stand-ins for the elements (a constant is itself, a constant start of a concatenation is that
// start plus "x", anything else "x"), and the list is cut where the program begins. The error is
// what Exec would say.
func (r *resolver) innerElts(w string, es []ast.Expr) ([]ast.Expr, error) {
	stand := make([]string, len(es))
	for i, e := range es {
		if s, ok := r.p.constString(e); ok {
			stand[i] = s
		} else if s, ok := r.p.leftConst(e); ok {
			stand[i] = s + "x"
		} else {
			stand[i] = "x"
		}
	}
	in, err := run.Inner(w, stand)
	if err != nil {
		return nil, err
	}
	if len(in) == 0 {
		return nil, fmt.Errorf("%s starts no program", w)
	}
	return es[len(es)-len(in):], nil
}

// leftConst: the constant start of a concatenation ("--unit=" + unit + "-" + n).
func (p *pkg) leftConst(e ast.Expr) (string, bool) {
	e = ast.Unparen(e)
	if s, ok := p.constString(e); ok {
		return s, true
	}
	if b, ok := e.(*ast.BinaryExpr); ok && b.Op == token.ADD {
		return p.leftConst(b.X)
	}
	if c, ok := e.(*ast.CallExpr); ok && len(c.Args) > 0 {
		if ip, n := p.qualified(c.Fun); ip == "fmt" && n == "Sprintf" {
			if f, ok := p.constString(c.Args[0]); ok {
				pre, _, _ := strings.Cut(f, "%")
				return pre, true
			}
		}
	}
	return "", false
}

// prog: the program names an expression of type string can be.
func (r *resolver) prog(e ast.Expr, site ast.Node) []string {
	p := r.p
	e = ast.Unparen(e)
	if s, ok := p.constString(e); ok {
		return []string{s}
	}
	if r.seen[e] {
		return nil
	}
	r.seen[e] = true
	switch e := e.(type) {
	case *ast.Ident:
		o := p.info.Uses[e]
		if o == nil {
			o = p.info.Defs[e]
		}
		if pr, ok := p.params[o]; ok {
			var out []string
			for _, c := range r.wrapper(pr, site, "prog") {
				out = append(out, c[0])
			}
			return out
		}
		if ds := p.defs[o]; len(ds) > 0 {
			var out []string
			for _, d := range ds {
				if d.index == 0 {
					out = append(out, r.prog(d.rhs, site)...)
				} else {
					p.report(site, "program", "the program %s is not the first value of its assignment", e.Name)
				}
			}
			return out
		}
	case *ast.CallExpr:
		var fn string
		switch f := e.Fun.(type) {
		case *ast.Ident:
			fn = f.Name
		case *ast.SelectorExpr:
			fn = f.Sel.Name
		}
		if i, ok := pathResolvers[fn]; ok && i < len(e.Args) {
			return r.prog(e.Args[i], site)
		}
	case *ast.SelectorExpr:
		if n, ok := dynamicPrograms[p.dir+" "+p.expr(e)]; ok {
			return []string{n}
		}
	}
	p.report(site, "program", "the program name %s is not a constant (see srv/README.md: how a program is added)", p.expr(e))
	return nil
}

// wrapper: the argument of a parameter that is the program (kind "prog") or the argv (kind
// "argv"): the function's callers in this package pass it. Exported functions may be called from
// other packages, which this does not see: refused.
func (r *resolver) wrapper(pr param, site ast.Node, kind string) []chain {
	p := r.p
	fn := pr.fn
	if fn.Name.IsExported() {
		p.report(site, "program", "the program comes from a parameter of the exported %s: callers in other packages are not followed; pass a constant or make it unexported", fn.Name.Name)
		return nil
	}
	key := fmt.Sprintf("%s#%d#%s", fn.Name.Name, pr.index, kind)
	if out, done := p.memo[key]; done {
		return out
	}
	p.memo[key] = nil // a wrapper that calls itself adds nothing the first pass did not
	sub := &resolver{p: p, seen: map[ast.Node]bool{}}
	var out []chain
	for _, call := range p.calls[fn.Name.Name] {
		if call.Ellipsis.IsValid() && pr.variadic && pr.index == len(call.Args)-1 {
			out = append(out, sub.argv(call.Args[pr.index], call)...)
			continue
		}
		if pr.index >= len(call.Args) {
			if pr.variadic {
				p.report(call, "program", "call of %s without a program", fn.Name.Name)
			}
			continue
		}
		p.scanShellConsts(call)
		switch {
		case kind == "prog":
			for _, n := range sub.prog(call.Args[pr.index], call) {
				out = append(out, chain{n})
			}
		case pr.variadic:
			out = append(out, sub.elts(call.Args[pr.index:], call)...)
		default:
			out = append(out, sub.argv(call.Args[pr.index], call)...)
		}
	}
	p.memo[key] = out
	return out
}

// checkLayers: cmd/* -> daemon -> domain -> internal/*.
func (p *pkg) checkLayers() {
	from := p.dir
	for _, f := range p.files {
		for _, im := range f.Imports {
			ip := strings.Trim(im.Path.Value, "`\"")
			to, ok := strings.CutPrefix(ip, p.module+"/")
			if !ok {
				continue
			}
			if msg := layerViolation(from, to); msg != "" {
				p.report(im, "layers", "%s imports %s: %s", from, to, msg)
			}
		}
	}
}

func top(d string) string { t, _, _ := strings.Cut(d, "/"); return t }

func layerViolation(from, to string) string {
	ft, tt := top(from), top(to)
	switch {
	case ft == "tools" || ft == ".":
		if tt == "cmd" || tt == "daemon" || domains[tt] {
			return "tools use internal/* only"
		}
		return ""
	case tt == "cmd":
		return "nothing imports a main package"
	case tt == "tools":
		return "nothing imports tools"
	case ft == "internal":
		if tt != "internal" {
			return "internal/* imports no domain package and not daemon"
		}
	case ft == "cmd":
		return "" // cmd/* wires everything: its domain package, daemon, daemon/proto, internal/*
	case from == "daemon/proto":
		if tt != "internal" {
			return "daemon/proto has no domain imports (tando-watch and tando-status link it)"
		}
	case ft == "daemon":
		if tt == "daemon" && to != "daemon/proto" {
			return "daemon imports its own sub-package other than proto"
		}
		if domains[tt] && to != tt {
			return "daemon composes the domain packages, not their sub-packages (internal/* is shared code)"
		}
	case domains[ft]:
		switch {
		case tt == "internal", tt == ft:
		case tt == "daemon":
			if to == "daemon/proto" {
				return "a domain package imports no daemon package (only cmd/tando-watch and cmd/tando-status import daemon/proto)"
			}
			return "only cmd/* imports daemon"
		default:
			return "a domain package imports no other domain package"
		}
	}
	if tt == "daemon" && ft != "cmd" && ft != "daemon" {
		return "only cmd/* imports daemon"
	}
	return ""
}

// checkProgramsFile compares the programs found with the checked-in list.
func (r *Result) checkProgramsFile(file string) {
	b, err := os.ReadFile(file)
	if err != nil {
		r.add(false, file, "program", "cannot read the list of programs: "+err.Error())
		return
	}
	have := map[string]bool{}
	for l := range strings.SplitSeq(string(b), "\n") {
		if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") {
			have[l] = true
		}
	}
	for _, l := range r.Programs {
		if !have[l] {
			r.add(false, file, "program", fmt.Sprintf("the tree runs %q, which is not in the list: add the line (go run ./tools/srvlint -list ./...), and the name to Programs in internal/run/programs.go", strings.ReplaceAll(l, "\t", " ")))
		}
		delete(have, l)
	}
	for l := range have {
		r.add(false, file, "program", fmt.Sprintf("the list has %q, which nothing runs any more: delete the line", strings.ReplaceAll(l, "\t", " ")))
	}
}

// CheckRunPrograms: the basenames run.Programs allows are exactly those the tree runs.
// CheckRunPrograms (the real tree only) compares the programs found with run.Programs.
func (r *Result) CheckRunPrograms() {
	if r.NPackages == 0 || len(r.Programs) == 0 {
		return
	}
	found := map[string]bool{}
	for _, l := range r.Programs {
		_, c, _ := strings.Cut(l, "\t")
		for _, n := range strings.Fields(c) {
			found[n] = true
		}
	}
	for _, p := range run.Programs {
		if !found[p] {
			r.add(false, "internal/run/programs.go", "program", fmt.Sprintf("Programs has %q, which nothing runs: delete it", p))
		}
		delete(found, p)
	}
	for n := range found {
		r.add(false, "internal/run/programs.go", "program", fmt.Sprintf("the tree runs %q, which is not in Programs: Exec would refuse it", n))
	}
}

// checkTableFile compares a generated table (the -args output) with its checked-in file.
func (r *Result) checkTableFile(file string, lines []string, group string) {
	b, err := os.ReadFile(file)
	if err != nil {
		r.add(false, file, group, "cannot read the table: "+err.Error())
		return
	}
	have := map[string]bool{}
	for l := range strings.SplitSeq(string(b), "\n") {
		if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") {
			have[l] = true
		}
	}
	for _, l := range lines {
		if !have[l] {
			r.add(false, file, group, fmt.Sprintf("the tree has %q, which is not in the table: regenerate it (go run ./tools/srvlint -args ./...) and review the diff", strings.ReplaceAll(l, "\t", " | ")))
		}
		delete(have, l)
	}
	for l := range have {
		r.add(false, file, group, fmt.Sprintf("the table has %q, which the tree no longer has: regenerate it", strings.ReplaceAll(l, "\t", " | ")))
	}
}
