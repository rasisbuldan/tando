package sqlsplit

import "strings"

// The scope guard, lexical half: the studio reads the app's own tables, never PostgreSQL's
// catalogs (pg_catalog, information_schema, pg_toast, any pg_* schema). The other half is the
// plan check in srv/studio (scope.go): the server's own EXPLAIN of each statement names every
// relation it will read, with its schema, after search_path and views. This half catches what a
// plan shows only as expression text, or not at all: catalog-reading functions, reg* casts that
// look a name up in the catalogs, and any system name written in the statement. Like the
// read-only guard it works on names, so it over-refuses (an app column called pg_x) rather than
// under-refuses; and a function the app itself defined is called by its own name (documented).

// okPg: pg_* functions that read no catalog and are everyday tools
var okPg = map[string]bool{"pg_sleep": true, "pg_sleep_for": true, "pg_sleep_until": true,
	"pg_typeof": true, "pg_size_pretty": true, "pg_size_bytes": true, "pg_column_size": true,
	"pg_input_is_valid": true, "pg_input_error_info": true,
	"pg_advisory_lock": true, "pg_advisory_lock_shared": true, "pg_advisory_unlock": true,
	"pg_advisory_unlock_shared": true, "pg_advisory_unlock_all": true, "pg_advisory_xact_lock": true,
	"pg_advisory_xact_lock_shared": true, "pg_try_advisory_lock": true, "pg_try_advisory_lock_shared": true,
	"pg_try_advisory_xact_lock": true, "pg_try_advisory_xact_lock_shared": true}

// catalogCalls: functions without the pg_ prefix that read the catalogs or the server's state
// (PostgreSQL's "System Information Functions" and "System Administration Functions"), or that
// take a table by name as text (implicitly a regclass: table_to_xml('pg_authid', ...))
var catalogCalls = map[string]bool{"current_setting": true, "current_schemas": true,
	"obj_description": true, "col_description": true, "shobj_description": true, "format_type": true,
	"row_security_active": true, "acldefault": true, "aclexplode": true,
	"table_to_xml": true, "table_to_xmlschema": true, "table_to_xml_and_xmlschema": true,
	"schema_to_xml": true, "schema_to_xmlschema": true, "schema_to_xml_and_xmlschema": true,
	"database_to_xml": true, "database_to_xmlschema": true, "database_to_xml_and_xmlschema": true,
	"brin_summarize_new_values": true, "brin_summarize_range": true, "brin_desummarize_range": true,
	"gin_clean_pending_list": true, "loread": true, "lowrite": true, "mxid_age": true}

// regTypes: the object-identifier types whose input looks a name up in the catalogs
var regTypes = map[string]bool{"class": true, "proc": true, "procedure": true, "type": true,
	"role": true, "namespace": true, "oper": true, "operator": true, "config": true,
	"dictionary": true, "collation": true, "typemod": true}

// SystemName says why a name (lowercased, unquoted) is out of the studio's scope, or "".
func SystemName(w string) string {
	w = strings.ToLower(w)
	switch {
	case w == "information_schema" || w == "pg_catalog" || w == "pg_toast" || strings.HasPrefix(w, "pg_temp"):
		return "a system schema"
	case strings.HasPrefix(w, "pg_") && !okPg[w]:
		return "a system table or function"
	case isReg(w):
		return "a lookup in the system tables"
	case catalogCalls[w], strings.HasPrefix(w, "has_") && strings.HasSuffix(w, "_privilege"),
		strings.HasPrefix(w, "txid_"), strings.HasPrefix(w, "lo_"):
		return "a function that reads the system tables"
	}
	return ""
}

// isReg: regclass, regclass[] (the name is the same), _regclass, to_regclass, regclassin/out/recv/send
func isReg(w string) bool {
	w = strings.TrimPrefix(strings.TrimPrefix(w, "_"), "to_")
	if !strings.HasPrefix(w, "reg") {
		return false
	}
	w = w[3:]
	if regTypes[w] {
		return true
	}
	for _, sfx := range []string{"in", "out", "recv", "send"} {
		if strings.HasSuffix(w, sfx) && regTypes[strings.TrimSuffix(w, sfx)] {
			return true
		}
	}
	return false
}

// Scope finds the first name in stmt that is out of the studio's scope: the name as written
// (unquoted), why, and its byte offset in stmt. "" when there is none. SHOW ALL is refused too
// (it is the pg_settings view); SHOW of one setting is not (no table is read).
func Scope(stmt string) (name, why string, at int) {
	if w := Words(stmt, 2); len(w) == 2 && w[0] == "show" && w[1] == "all" {
		return "SHOW ALL", "the server's settings table (SHOW one setting instead)", 0
	}
	idents(stmt, func(w string, i int) bool {
		if why = SystemName(w); why != "" {
			name, at = w, i
			return false
		}
		return true
	})
	if why == "a system table or function" { // which: a call has its '(' next
		why = "a system table"
		j := at
		if stmt[j] == '"' {
			j = skipQuote(stmt, j+1, '"', false)
		} else {
			_, j = word(stmt, j)
		}
		if j = skipSpace(stmt, j); j < len(stmt) && stmt[j] == '(' {
			why = "a system function"
		}
	}
	return name, why, at
}

// explainOpts: the words that start an option of EXPLAIN's list form; after "EXPLAIN (" anything
// else starts the statement, as in PostgreSQL's grammar (EXPLAIN (SELECT 1) explains SELECT 1)
var explainOpts = map[string]bool{"analyze": true, "analyse": true, "verbose": true, "costs": true,
	"settings": true, "generic_plan": true, "buffers": true, "serialize": true, "wal": true,
	"timing": true, "summary": true, "memory": true, "format": true}

// ExplainTarget: the statement an EXPLAIN [ANALYZE] [VERBOSE] or EXPLAIN (options) explains, and
// its byte offset in stmt; "" if stmt is not an EXPLAIN this can read (the caller refuses it).
func ExplainTarget(stmt string) (string, int) {
	i := skipSpace(stmt, 0)
	if w, j := word(stmt, i); w == "explain" {
		i = skipSpace(stmt, j)
	} else {
		return "", 0
	}
	if i < len(stmt) && stmt[i] == '(' {
		if w, _ := word(stmt, skipSpace(stmt, i+1)); explainOpts[w] {
			j := i + 1
			for j < len(stmt) && stmt[j] != ')' {
				switch stmt[j] {
				case '\'':
					j = skipQuote(stmt, j+1, '\'', false)
				case '"':
					j = skipQuote(stmt, j+1, '"', false)
				case '(', ';':
					return "", 0
				default:
					j++
				}
			}
			if j >= len(stmt) {
				return "", 0
			}
			i = skipSpace(stmt, j+1)
		}
	} else {
		for {
			w, j := word(stmt, i)
			if w != "analyze" && w != "analyse" && w != "verbose" {
				break
			}
			i = skipSpace(stmt, j)
		}
	}
	if i >= len(stmt) {
		return "", 0
	}
	return stmt[i:], i
}

// skipSpace: the index of the first byte from i that is not white space or a comment
func skipSpace(s string, i int) int {
	for i < len(s) {
		switch {
		case isSpace(s[i]):
			i++
		case s[i] == '-' && i+1 < len(s) && s[i+1] == '-':
			for i < len(s) && s[i] != '\n' {
				i++
			}
		case s[i] == '/' && i+1 < len(s) && s[i+1] == '*':
			i = skipBlock(s, i)
		default:
			return i
		}
	}
	return i
}

// word: the plain (unquoted) word at i, lowercased, and the index after it
func word(s string, i int) (string, int) {
	j := i
	for j < len(s) && isIdent(s[j]) && s[j] != '$' {
		j++
	}
	return strings.ToLower(s[i:j]), j
}

// Idents calls fn with each identifier of stmt outside quotes and comments and its byte offset
// (see idents), until fn returns false.
func Idents(stmt string, fn func(word string, at int) bool) { idents(stmt, fn) }
