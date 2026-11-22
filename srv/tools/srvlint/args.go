package main

import (
	"fmt"
	"go/ast"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"tando/srv/internal/run"
)

// The -args table: for every place that lists the arguments of a program (a run.Cmd literal, or
// a call of a helper such as quiet(...) whose arguments become an argv), one line
//
//	<file> <function> TAB <program> TAB <the argv as a template>
//
// where a constant is shown as it is, a constant start of a concatenation as `--unit=<..>`, a
// number as `<int>`, and every other argument as one of
//
//	<valid:WHY>   the value is validated before it gets here (WHY names the function; the table
//	              claims in `validated` below are reviewed claims, each with its reason)
//	<after--:X>   comes after a constant "--": the program takes it as an operand
//	<other:X>     none of these: a finding, to be made validated or put after "--"
//
// A change in the table is a change in what a program is given; review it like a diff of code.

type argElem struct {
	text string
	kind string // const, prefixed, int, valid, after--, other
	expr string // the expression as written (for the claims)
}

type argList struct {
	origin ast.Node
	elems  []argElem
}

// validated: arguments that are not constants and are reviewed claims, keyed by "<package dir>
// <program> <expression as written>". The reason says what validates them; the argument tests
// and the callers are what the claim rests on.
var validated = map[string]string{
	"gate /usr/bin/rsync args": "checkRsyncOpts (gate/rsync.go): only the receiver's options; no -e, --rsh, --rsync-path (request_test.go)",

	// the gate: app is valid.App ([a-z][a-z0-9-]{1,25}) before any verb runs; the rest is what the
	// request grammar and the stdin parameters accept
	"gate tando-agent app":          "valid.App: starts with a letter",
	"gate tando-agent req.ID":       "valid.ID: digits and '-' in a fixed shape, starts with a digit (request.go)",
	"gate tando-agent req.HistoryN": "1-3 digits (request.go)",
	"gate tando-agent req.Wait":     "waitRe: wait=[a-z]{1,16}, never starts with - (request.go)",
	"gate tando-agent p.Token":      "validToken (gate.go tokenRe)",
	"gate tando-agent l.Token":      "read back from the lease file, written by the gate from a validToken value",
	"gate tando-agent string(m[1])": "the token the agent printed, matched by a token regexp (rootmode.go)",
	"gate tando-agent p.Build":      "validSecs: digits",
	"gate tando-agent p.Upload":     "validSecs: digits",
	"gate tando-agent pv":           "ValidPreview(app, name): <app>-<slug>, a valid.App name (preview.go), checked in rootPreview",
	"gate tando-agent p.TTL":        "previewTTLRe: 1-4 digits and one of s m h d, never starts with - (params.go, preview.go)",
	"gate ipcrm f[1]":               "uintOf(f[1]) must succeed before the call (procs.go)",

	// the other programs: app is valid.App at the entry of every verb
	"status tando-watch name":   "valid.App at the verb's entry (starts with a letter)",
	"status tando-logs name":    "valid.App at the verb's entry",
	"status tando-metrics name": "valid.App at the verb's entry",
	"status tando-agent name":   "valid.App at the verb's entry",
	"watch tando-agent a.name":  "an app of apps.Names: valid.App",
	"logs journalctl p.args...": "built only by appending --namespace=, -u <unit>, --since=@, --until=@ and numbers (query.go)",

	// host care: the apps whose backup is taken before a reboot
	"hostcare /opt/tando/bin/tando-agent app": "staleBackups: names of backups(), each valid.App (starts with a letter)",
}

// valueFlags: options whose next argument is their value (it cannot be read as an option).
var valueFlags = map[string]bool{
	"-f": true, "-u": true, "-t": true, "-p": true, "-n": true, "-o": true, "-g": true,
	"--home-dir": true, "--shell": true, "--comment": true, "--config": true, "--adapter": true,
	"--namespace": true, "--since": true, "--until": true, "--signal": true,
}

// pathFuncs return absolute paths built from the configured root and a validated name: the value
// starts with "/", so it cannot be read as an option.
var pathFuncs = map[string]bool{"bin": true, "appDir": true, "incoming": true, "which": true, "lookTool": true}

// intFuncs format a number.
var intFuncs = map[string]bool{"Itoa": true, "FormatInt": true, "FormatUint": true, "itoa": true}

type argResolver struct {
	p       *pkg
	seen    map[ast.Node]bool
	prog    *resolver
	tracing map[string]bool
}

func (p *pkg) argTable(res map[string]bool, counts map[string]int) {
	if p.dir == "internal/run" {
		return
	}
	p.mute = true
	defer func() { p.mute = false }()
	var sites []ast.Expr
	for _, f := range p.files {
		if strings.HasSuffix(p.fset.Position(f.Pos()).Filename, "_test.go") {
			continue
		}
		ast.Inspect(f, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.CompositeLit:
				if n.Type != nil && p.isRunCmd(n.Type) {
					for _, e := range n.Elts {
						if kv, ok := e.(*ast.KeyValueExpr); ok {
							if k, _ := kv.Key.(*ast.Ident); k != nil && k.Name == "Argv" {
								sites = append(sites, kv.Value)
							}
						}
					}
				}
			case *ast.AssignStmt:
				for i, l := range n.Lhs {
					if s, ok := l.(*ast.SelectorExpr); ok && s.Sel.Name == "Argv" && len(n.Rhs) == len(n.Lhs) {
						sites = append(sites, n.Rhs[i])
					}
				}
			}
			return true
		})
	}
	for _, e := range sites {
		ar := &argResolver{p: p, seen: map[ast.Node]bool{}, prog: &resolver{p: p, seen: map[ast.Node]bool{}}, tracing: map[string]bool{}}
		for _, l := range ar.lists(e, 0) {
			if len(l.elems) == 0 {
				continue
			}
			p.addArgLine(l, res, counts)
		}
	}
}

func (p *pkg) funcOf(n ast.Node) string {
	for _, f := range p.files {
		if n.Pos() < f.Pos() || n.Pos() > f.End() {
			continue
		}
		for _, d := range f.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok && n.Pos() >= fd.Pos() && n.Pos() <= fd.End() {
				return fd.Name.Name
			}
		}
	}
	return "-"
}

func (p *pkg) addArgLine(l argList, res map[string]bool, counts map[string]int) {
	file := filepath.ToSlash(p.fset.Position(l.origin.Pos()).Filename)
	file = file[strings.Index(file, p.dir):]
	var parts []string
	prog := l.elems[0].text
	afterDD := false
	for i, e := range l.elems {
		if e.kind == "other" && afterDD {
			e = argElem{strings.Replace(e.text, "<other:", "<after--:", 1), "after--", e.expr}
			l.elems[i] = e
		}
		if e.kind == "const" && e.text == "--" {
			afterDD = true
		}
		if e.kind == "other" {
			for _, c := range l.elems {
				if c.kind == "const" {
					if _, ok := validated[p.dir+" "+strings.Trim(c.text, `"`)+" "+e.expr]; ok {
						e = argElem{"<valid:" + e.expr + ">", "valid", ""}
						l.elems[i] = e
						break
					}
				}
			}
		}
		counts[e.kind]++
		parts = append(parts, e.text)
		if i > 0 && e.kind == "other" {
			p.res.add(false, p.pos(l.origin), "args", fmt.Sprintf("argument %s of %s is neither constant, nor validated, nor after \"--\": validate it, or put it after --", e.text, prog))
		}
	}
	line := strings.TrimSpace(fmt.Sprintf("%s %s\t%s\t%s", file, p.funcOf(l.origin), prog, strings.Join(parts, " ")))
	res[line] = true
	p.checkShape(l, prog)
}

// lists: the possible argument lists of an expression of type []string.
func (a *argResolver) lists(e ast.Expr, depth int) []argList {
	p := a.p
	e = ast.Unparen(e)
	if depth > 12 {
		return []argList{{e, []argElem{{"<other:" + p.expr(e) + ">", "other", p.expr(e)}}}}
	}
	switch e := e.(type) {
	case *ast.CompositeLit:
		return []argList{{e, a.classifyAll(e.Elts)}}
	case *ast.CallExpr:
		if id, ok := e.Fun.(*ast.Ident); ok && id.Name == "append" && len(e.Args) > 0 {
			base := a.lists(e.Args[0], depth+1)
			return a.extend(base, e.Args[1:], e.Ellipsis.IsValid(), e, depth)
		}
	case *ast.SelectorExpr:
		if e.Sel.Name == "Argv" {
			return nil
		}
	case *ast.Ident:
		o := p.info.Uses[e]
		if o == nil {
			o = p.info.Defs[e]
		}
		if pr, ok := p.params[o]; ok {
			return a.paramLists(pr, depth, true)
		}
		if ds := p.defs[o]; len(ds) > 0 {
			var base []argList
			var exts []ast.Expr
			for _, d := range ds {
				if d.n != 1 {
					continue
				}
				if c, ok := d.rhs.(*ast.CallExpr); ok && len(c.Args) > 0 {
					if id, ok := c.Fun.(*ast.Ident); ok && id.Name == "append" {
						if a0, ok := ast.Unparen(c.Args[0]).(*ast.Ident); ok && p.info.Uses[a0] == o {
							exts = append(exts, c)
							continue
						}
					}
				}
				base = append(base, a.lists(d.rhs, depth+1)...)
			}
			for _, x := range exts {
				c := x.(*ast.CallExpr)
				base = a.extend(base, c.Args[1:], c.Ellipsis.IsValid(), c, depth)
			}
			return base
		}
	}
	return []argList{{e, []argElem{{"<other:" + p.expr(e) + ">", "other", p.expr(e)}}}}
}

// extend appends the arguments of an append call (a spread last one, if ellipsis) to each list.
func (a *argResolver) extend(base []argList, args []ast.Expr, ellipsis bool, at ast.Node, depth int) []argList {
	var fixed []ast.Expr
	var spread ast.Expr
	if ellipsis && len(args) > 0 {
		fixed, spread = args[:len(args)-1], args[len(args)-1]
	} else {
		fixed = args
	}
	tails := []argList{{at, a.classifyAll(fixed)}}
	if spread != nil {
		var next []argList
		for _, t := range tails {
			for _, s := range a.spreadLists(spread, depth) {
				next = append(next, argList{t.origin, append(append([]argElem{}, t.elems...), s.elems...)})
			}
		}
		tails = next
	}
	var out []argList
	for _, b := range base {
		for _, t := range tails {
			out = append(out, argList{b.origin, append(append([]argElem{}, b.elems...), t.elems...)})
		}
	}
	return out
}

// spreadLists: the elements an expression of type []string adds when spread with "...".
func (a *argResolver) spreadLists(e ast.Expr, depth int) []argList {
	p := a.p
	e = ast.Unparen(e)
	if id, ok := e.(*ast.Ident); ok {
		if pr, ok := p.params[p.info.Uses[id]]; ok {
			return a.paramLists(pr, depth, false)
		}
	}
	if _, ok := e.(*ast.CompositeLit); ok {
		return a.lists(e, depth+1)
	}
	if id, ok := e.(*ast.Ident); ok {
		if ds := p.defs[p.info.Uses[id]]; len(ds) > 0 {
			return a.lists(e, depth+1)
		}
	}
	return []argList{{e, []argElem{{"<other:" + p.expr(e) + "...>", "other", p.expr(e) + "..."}}}}
}

// paramLists: the lists the callers of a function pass for its parameter (argv-like: a slice, or
// variadic strings); the callers are in this package (an exported function is refused elsewhere).
func (a *argResolver) paramLists(pr param, depth int, isArgv bool) []argList {
	p := a.p
	key := fmt.Sprintf("%s#%d", pr.fn.Name.Name, pr.index)
	var out []argList
	for _, call := range p.calls[pr.fn.Name.Name] {
		if pr.index >= len(call.Args) {
			continue
		}
		if p.isTestPos(call) {
			continue
		}
		if a.seen[call] {
			continue
		}
		a.seen[call] = true
		switch {
		case call.Ellipsis.IsValid() && pr.variadic && pr.index == len(call.Args)-1:
			out = append(out, a.lists(call.Args[pr.index], depth+1)...)
		case pr.variadic:
			out = append(out, argList{call, a.classifyAll(call.Args[pr.index:])})
		default:
			out = append(out, a.lists(call.Args[pr.index], depth+1)...)
		}
	}
	_ = key
	return out
}

func (p *pkg) isTestPos(n ast.Node) bool { return p.isTest(n) }

func (a *argResolver) classifyAll(es []ast.Expr) []argElem {
	var out []argElem
	afterDD := false
	inner := -1 // the program a wrapper starts
	if len(es) > 0 {
		first := a.classify(es[0], true)
		if w := filepath.Base(strings.Split(first.text, "|")[0]); contains(run.Wrappers(), w) {
			if in, err := a.prog.innerElts(w, es[1:]); err == nil {
				inner = len(es) - len(in)
			}
		}
	}
	for i, e := range es {
		el := a.classify(e, i == 0 || i == inner)
		if i > 0 && el.kind == "other" && out[i-1].kind == "const" && valueFlags[strings.Trim(out[i-1].text, `"`)] {
			el = argElem{"<value-of:" + strings.Trim(out[i-1].text, `"`) + ":" + el.expr + ">", "valueof", el.expr}
		}
		if afterDD && el.kind == "other" {
			el = argElem{strings.Replace(el.text, "<other:", "<after--:", 1), "after--", el.expr}
		}
		if el.kind == "const" && el.text == "--" {
			afterDD = true
		}
		out = append(out, el)
	}
	return out
}

// classify: one element. The program (the first element) is shown by name, as the program
// resolver finds it.
func (a *argResolver) classify(e ast.Expr, first bool) argElem {
	p := a.p
	if first {
		var names []string
		for _, n := range (&resolver{p: p, seen: map[ast.Node]bool{}}).prog(e, e) {
			names = append(names, n)
		}
		if len(names) > 0 {
			sort.Strings(names)
			return argElem{strings.Join(names, "|"), "const", ""}
		}
	}
	e = ast.Unparen(e)
	if s, ok := p.constString(e); ok {
		return argElem{quote(s), "const", ""}
	}
	if s, ok := p.leftConst(e); ok && s != "" {
		return argElem{quote(s) + "<..>", "prefixed", ""}
	}
	switch x := e.(type) {
	case *ast.CallExpr:
		fn := calleeName(x)
		if intFuncs[fn] {
			return argElem{"<int>", "int", ""}
		}
		if pathFuncs[fn] {
			return argElem{"<path:" + fn + "()>", "valid", ""}
		}
		if fn == "Join" && len(x.Args) >= 2 {
			if s, ok := p.constString(x.Args[len(x.Args)-1]); ok {
				return argElem{"<valid:joined path .../" + s + ">", "valid", ""}
			}
		}
	case *ast.Ident:
		o := p.info.Uses[x]
		if ds := p.defs[o]; len(ds) == 1 && ds[0].n == 1 && ds[0].index == 0 {
			if el := a.classify(ds[0].rhs, false); el.kind != "other" {
				return el
			}
		} else if len(ds) > 1 {
			ok := true
			for _, d := range ds {
				if d.n != 1 || d.index != 0 || a.classify(d.rhs, false).kind == "other" {
					ok = false
				}
			}
			if ok {
				return argElem{fmt.Sprintf("<%s: %d assignments, each constant-led or validated>", x.Name, len(ds)), "valid", ""}
			}
		}
		if rx, ok := p.ranges[o]; ok {
			if cl, ok := ast.Unparen(rx).(*ast.CompositeLit); ok {
				var vals []string
				for _, e := range cl.Elts {
					s, isC := p.constString(e)
					if !isC {
						vals = nil
						break
					}
					vals = append(vals, s)
				}
				if vals != nil {
					return argElem{"<one of " + strings.Join(vals, "|") + ">", "const", ""}
				}
			}
		}
		// a parameter: what the callers pass (all of them constants or validated)
		if pr, ok := p.params[o]; ok && !pr.variadic && !a.tracing[x.Name+fmt.Sprint(pr.index)] {
			a.tracing[x.Name+fmt.Sprint(pr.index)] = true
			defer delete(a.tracing, x.Name+fmt.Sprint(pr.index))
			var kinds []string
			n := 0
			for _, call := range p.calls[pr.fn.Name.Name] {
				if pr.index >= len(call.Args) || p.isTest(call) {
					continue
				}
				n++
				el := a.classify(call.Args[pr.index], false)
				if el.kind == "other" {
					return argElem{"<other:" + p.expr(e) + ">", "other", p.expr(e)}
				}
				kinds = append(kinds, el.kind)
			}
			if n > 0 {
				return argElem{"<param " + x.Name + ": callers pass constants or validated values>", "valid", ""}
			}
		}
	}
	return argElem{"<other:" + p.expr(e) + ">", "other", p.expr(e)}
}

func calleeName(c *ast.CallExpr) string {
	switch f := c.Fun.(type) {
	case *ast.Ident:
		return f.Name
	case *ast.SelectorExpr:
		return f.Sel.Name
	}
	return ""
}

func quote(s string) string {
	if s == "" || strings.ContainsAny(s, " \t\n<>") {
		return fmt.Sprintf("%q", s)
	}
	return s
}

// shapes: the argument lists a program may have, where a token is a constant that must match,
// "*" one argument that is not "other", "**" one that is a constant, prefixed, number or validated, and "..." any rest (still not "other"). A list that
// matches none is a finding. The programs of the reviewer's list, plus what the gate and the
// watch run with a fixed form. (journalctl, systemctl, loginctl and the gate's account tools take
// many forms: they are held to the rule that nothing in them is "other".)
var shapes = map[string][]string{
	"python3":  {"-I -c *"},
	"node":     {"--version"},
	"caddy":    {"version", "validate --config * --adapter caddyfile"},
	"sendmail": {"-t -oi"},
	"nft":      {"list table inet tando", "-f **"}, // ** : a constant, or a path joined to a fixed name; never an unknown value
	"du":       {"-smxc -- ..."},
	"visudo":   {"-c -q -f *"},
	"crontab":  {"-r -u *"},
	"uname":    {"-m"},
}

// forbiddenArgs: constants a program is never given, whatever the shape (rsync's remote shell,
// sendmail's other configuration, du's file list).
var forbiddenArgs = map[string]*regexp.Regexp{
	"rsync":    regexp.MustCompile(`^(-e|-[a-zA-Z]*e|--rsh(=.*)?|--rsync-path(=.*)?|--files-from.*|--config.*|--daemon|-E)$`),
	"sendmail": regexp.MustCompile(`^(-C.*|-X.*|-O.*|-oA.*|-bs|-bd)$`),
	"du":       regexp.MustCompile(`^--files0-from.*$`),
	"nft":      regexp.MustCompile(`^(-i|--interactive|-I|--includepath.*)$`),
}

func (p *pkg) checkShape(l argList, prog string) {
	els := l.elems[1:]
	// the program, or the programs one helper runs with different arguments (status's tool): the
	// arguments must fit a form of one of them (they are all constants there)
	var tmpls []string
	known := true
	for _, b := range strings.Split(prog, "|") {
		base := filepath.Base(b)
		if re := forbiddenArgs[base]; re != nil {
			for _, e := range els {
				if e.kind == "const" && re.MatchString(strings.Trim(e.text, `"`)) {
					p.res.add(false, p.pos(l.origin), "args", fmt.Sprintf("%s is never given %s", base, e.text))
				}
			}
		}
		if t, ok := shapes[base]; ok {
			tmpls = append(tmpls, t...)
		} else {
			known = false
		}
	}
	if filepath.Base(prog) == "journalctl" {
		ok := false
		for _, e := range els {
			t := strings.Trim(e.text, `"`)
			if (e.kind == "const" || e.kind == "prefixed") && (t == "--no-pager" || t == "--disk-usage" || t == "--rotate" || strings.HasPrefix(t, "--vacuum-")) {
				ok = true // an operation that prints no log, or never pages
			}
		}
		if !ok {
			p.res.add(false, p.pos(l.origin), "args", "journalctl without --no-pager (and not an operation that prints no log): it could start a pager")
		}
	}
	if !known || len(tmpls) == 0 {
		return
	}
	base := prog
	for _, t := range tmpls {
		if matchShape(strings.Fields(t), els) {
			return
		}
	}
	var got []string
	for _, e := range els {
		got = append(got, e.text)
	}
	p.res.add(false, p.pos(l.origin), "args", fmt.Sprintf("%s is run with %q, which is none of its allowed forms %q", base, strings.Join(got, " "), tmpls))
}

func matchShape(t []string, els []argElem) bool {
	for i, tok := range t {
		if tok == "..." {
			for _, e := range els[min(i, len(els)):] {
				if e.kind == "other" {
					return false
				}
			}
			return true
		}
		if i >= len(els) {
			return false
		}
		e := els[i]
		if tok == "*" {
			if e.kind == "other" {
				return false
			}
			continue
		}
		if tok == "**" {
			if e.kind == "other" || e.kind == "valueof" || e.kind == "after--" {
				return false
			}
			continue
		}
		if e.kind != "const" || strings.Trim(e.text, `"`) != tok {
			return false
		}
	}
	return len(els) == len(t)
}
