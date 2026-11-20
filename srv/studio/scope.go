package studio

import (
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"unicode/utf8"

	"tando/srv/studio/pgwire"
	"tando/srv/studio/sqlsplit"
)

// The scope guard: the editor reads the app's own tables, never PostgreSQL's catalogs. Two
// halves, both before a statement runs (docs/ARCHITECTURE.md "db studio"):
//
//   - sqlsplit.Scope, on the text of every statement of the batch before anything runs: a
//     system schema or pg_* name, a reg* lookup, a catalog-reading function, SHOW ALL.
//   - planScope, here, on the server's own plan of each SELECT / WITH / VALUES / TABLE (and of
//     the statement a user's EXPLAIN explains), asked for in the same read-only transaction
//     right before the statement runs: EXPLAIN (VERBOSE, FORMAT JSON), never ANALYZE. The plan
//     names every relation the statement reads with its schema, after search_path, quoting and
//     views (a view of the app's that reads pg_roles shows pg_catalog.pg_authid), and every
//     expression as text, which gets the name check of the first half (a view's
//     current_setting(), a regclass cast). Fail closed: no plan, a plan too large, an unknown
//     node type, a relation without a schema: refused.
//
// It is a guard that keeps the studio to the app's tables, not a sandbox: a function the app
// defined that reads a catalog inside its body shows in a plan only by its own name (documented).

const (
	explainPrefix = "EXPLAIN (VERBOSE, FORMAT JSON) "
	PlanBytes     = 1 << 20 // the largest plan the studio reads (a bigger one: refused)
	scopeCode     = "42501"
)

// scopeMsg: what a refused statement says
func scopeMsg(name, why string) string {
	return "the studio only reads this app's own tables: " + name + " is " + why
}

// planNodes: the node types of PostgreSQL's EXPLAIN (explain.c); anything else is refused
var planNodes = map[string]bool{"Result": true, "ProjectSet": true, "ModifyTable": true, "Append": true,
	"Merge Append": true, "Recursive Union": true, "BitmapAnd": true, "BitmapOr": true, "Nested Loop": true,
	"Merge Join": true, "Hash Join": true, "Seq Scan": true, "Sample Scan": true, "Gather": true,
	"Gather Merge": true, "Index Scan": true, "Index Only Scan": true, "Bitmap Index Scan": true,
	"Bitmap Heap Scan": true, "Tid Scan": true, "Tid Range Scan": true, "Subquery Scan": true,
	"Function Scan": true, "Table Function Scan": true, "Values Scan": true, "CTE Scan": true,
	"Named Tuplestore Scan": true, "WorkTable Scan": true, "Foreign Scan": true, "Custom Scan": true,
	"Materialize": true, "Memoize": true, "Sort": true, "Incremental Sort": true, "Group": true,
	"Aggregate": true, "WindowAgg": true, "Unique": true, "SetOp": true, "LockRows": true, "Limit": true,
	"Hash": true}

// systemSchema: pg_catalog, information_schema, pg_toast, pg_temp_N, any pg_*
func systemSchema(s string) bool { return s == "information_schema" || strings.HasPrefix(s, "pg_") }

// errPlan: the plan could not be read; the statement is refused
var errPlan = errors.New("the studio could not check this statement (its plan could not be read): it is not run")

// planScope reads EXPLAIN (FORMAT JSON) output: the first out-of-scope name ("schema.name" for a
// relation) and why, or "" when everything is in scope; an error when the plan cannot be read.
func planScope(plan []byte) (name, why string, err error) {
	if len(plan) > PlanBytes {
		return "", "", errPlan
	}
	var top []map[string]any
	if json.Unmarshal(plan, &top) != nil || len(top) != 1 {
		return "", "", errPlan
	}
	root, ok := top[0]["Plan"].(map[string]any)
	if !ok {
		return "", "", errPlan
	}
	return walkNode(root, 0)
}

// walkNode: the relations and functions of the node and its children first (their message
// names the schema), then the text of every expression; keys in order, so the answer is stable
func walkNode(n map[string]any, depth int) (string, string, error) {
	if name, why, err := walkRels(n, depth); name != "" || err != nil {
		return name, why, err
	}
	name, why := walkExprs(n)
	return name, why, nil
}

func walkRels(n map[string]any, depth int) (string, string, error) {
	if depth > 200 {
		return "", "", errPlan
	}
	if t, _ := n["Node Type"].(string); !planNodes[t] {
		return "", "", errPlan
	}
	if rel, ok := n["Relation Name"]; ok {
		r, _ := rel.(string)
		sch, _ := n["Schema"].(string)
		if r == "" || sch == "" {
			return "", "", errPlan
		}
		if systemSchema(sch) {
			return sch + "." + r, "a system table", nil
		}
	}
	if fn, ok := n["Function Name"].(string); ok {
		sch, _ := n["Schema"].(string)
		if why := sqlsplit.SystemName(fn); why != "" {
			return sch + "." + fn, why, nil
		}
	}
	if v, ok := n["Plans"]; ok {
		kids, ok := v.([]any)
		if !ok {
			return "", "", errPlan
		}
		for _, c := range kids {
			m, ok := c.(map[string]any)
			if !ok {
				return "", "", errPlan
			}
			if name, why, err := walkRels(m, depth+1); name != "" || err != nil {
				return name, why, err
			}
		}
	}
	return "", "", nil
}

// walkExprs: the name check on every text of a node and its children (Output, Filter, Function
// Call, Index Cond, Sort Key, ...: expressions as the server prints them, a view's included).
// A node's Schema is left out: a relation's was checked by walkRels, and a function's may be
// pg_catalog (generate_series). The tree's shape was checked by walkRels.
func walkExprs(n map[string]any) (string, string) {
	for _, k := range sortedKeys(n) {
		switch k {
		case "Schema":
		case "Plans":
			kids, _ := n[k].([]any)
			for _, c := range kids {
				if m, ok := c.(map[string]any); ok {
					if name, why := walkExprs(m); name != "" {
						return name, why
					}
				}
			}
		default:
			if name, why := exprScope(n[k], 0); name != "" {
				return name, why
			}
		}
	}
	return "", ""
}

// exprScope: the name check on a value: a text, or the texts in a list or an object
func exprScope(v any, depth int) (string, string) {
	if depth > 20 {
		return "(plan)", "too deep to check"
	}
	switch x := v.(type) {
	case string:
		if name, why, _ := sqlsplit.Scope(x); name != "" {
			return name, why
		}
	case []any:
		for _, e := range x {
			if name, why := exprScope(e, depth+1); name != "" {
				return name, why
			}
		}
	case map[string]any:
		for _, k := range sortedKeys(x) {
			if name, why := exprScope(x[k], depth+1); name != "" {
				return name, why
			}
		}
	}
	return "", ""
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// scopeRefusal: a view's rows refused by the plan check (403 with the message)
type scopeRefusal string

func (e scopeRefusal) Error() string { return string(e) }

// planSink keeps EXPLAIN's one cell and whether it was cut
type planSink struct {
	rows int
	cell []byte
	cut  bool
}

func (p *planSink) Columns([]pgwire.Field) error { return nil }
func (p *planSink) Row(cells [][]byte, full []int) error {
	p.rows++
	if len(cells) != 1 || cells[0] == nil || full[0] >= 0 {
		p.cut = true
		return nil
	}
	p.cell = append(p.cell[:0], cells[0]...)
	return nil
}

// scopeErr: a refusal as the statement's error (position 1-based in the statement, 0: none)
func scopeErr(msg string, pos int) *pgwire.Error {
	return &pgwire.Error{Code: scopeCode, Message: msg, Position: pos}
}

// planCheck asks the server for the plan of the statement (or of the statement a user's EXPLAIN
// explains) and checks it. SHOW, SET and RESET have no plan: their text was checked up front.
// It returns the statement's error (nil: in scope), or a connection error.
func (x *txn) planCheck(stmt string) (*pgwire.Error, error) {
	inner, off := stmt, 0
	switch w := sqlsplit.Words(stmt, 1); {
	case len(w) == 0:
		return scopeErr(errPlan.Error(), 0), nil
	case w[0] == "show" || w[0] == "set" || w[0] == "reset":
		return nil, nil
	case w[0] == "explain":
		if inner, off = sqlsplit.ExplainTarget(stmt); inner == "" {
			return scopeErr(errPlan.Error(), 0), nil
		}
	}
	ps := &planSink{}
	res, err := x.exec(explainPrefix+inner, nil, 0, PlanBytes, PlanBytes+1024, ps)
	if err != nil {
		return nil, err
	}
	if res.Err != nil { // the statement's own error (syntax, no such table, ...), at its place
		e := *res.Err
		if pre := utf8.RuneCountInString(explainPrefix); e.Position > pre {
			e.Position += utf8.RuneCountInString(stmt[:off]) - pre
		} else {
			e.Position = 0
		}
		return &e, nil
	}
	if ps.rows != 1 || ps.cut || res.Stopped {
		return scopeErr(errPlan.Error(), 0), nil
	}
	name, why, perr := planScope(ps.cell)
	if perr != nil {
		return scopeErr(perr.Error(), 0), nil
	}
	if name == "" {
		return nil, nil
	}
	return scopeErr(scopeMsg(name, why), namePos(stmt, name)), nil
}

// namePos: where the statement names the plan's relation (its last part), 1-based in
// characters; 0 when it does not (a view's)
func namePos(stmt, name string) int {
	last := strings.ToLower(name[strings.LastIndexByte(name, '.')+1:])
	pos := 0
	sqlsplit.Idents(stmt, func(w string, at int) bool {
		if strings.ToLower(w) == last {
			pos = utf8.RuneCountInString(stmt[:at]) + 1
			return false
		}
		return true
	})
	return pos
}
