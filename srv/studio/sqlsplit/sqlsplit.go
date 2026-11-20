// Package sqlsplit splits the text of the studio's editor into statements and reads their first
// words. It is not the read-only boundary: each piece goes to PostgreSQL in a Parse message,
// which refuses a string with two commands, inside a read-only transaction. A splitter mistake
// therefore gives a syntax error, never a second statement. ReadOnly is the accident guard on
// top (statements other than queries are refused before they reach the server).
package sqlsplit

import (
	"strings"
	"unicode/utf8"
)

// Stmt is one statement: its text (without the ';'), its byte range in the input and the
// code-point offset of its first character (PostgreSQL's error positions count characters).
type Stmt struct {
	Text       string
	Start, End int
	CP         int
}

// Split cuts sql at the semicolons outside quotes and comments. Pieces holding nothing but
// white space and comments are dropped. It understands '...' (with ”), E'...' (with
// backslashes), "..." (with ""), $tag$...$tag$, -- comments and nested /* */ comments; an
// unterminated quote or comment runs to the end of the input.
func Split(sql string) []Stmt {
	var out []Stmt
	start := 0
	i := 0
	n := len(sql)
	content := false // the piece has something besides space and comments
	emit := func(end int) {
		if content {
			s := start
			for s < end && isSpace(sql[s]) {
				s++
			}
			e := end
			for e > s && isSpace(sql[e-1]) {
				e--
			}
			out = append(out, Stmt{Text: sql[s:e], Start: s, End: e, CP: utf8.RuneCountInString(sql[:s])})
		}
		content = false
	}
	for i < n {
		c := sql[i]
		switch {
		case c == ';':
			emit(i)
			i++
			start = i
			continue
		case c == '-' && i+1 < n && sql[i+1] == '-':
			for i < n && sql[i] != '\n' {
				i++
			}
			continue
		case c == '/' && i+1 < n && sql[i+1] == '*':
			i = skipBlock(sql, i)
			continue
		case isSpace(c):
			i++
			continue
		}
		content = true
		switch {
		case c == '\'':
			esc := i > 0 && (sql[i-1] == 'E' || sql[i-1] == 'e') && (i < 2 || !isIdent(sql[i-2]))
			i = skipQuote(sql, i+1, '\'', esc)
		case c == '"':
			i = skipQuote(sql, i+1, '"', false)
		case c == '$' && (i == 0 || !isIdent(sql[i-1])):
			if tag, ok := dollarTag(sql, i); ok {
				j := strings.Index(sql[i+len(tag):], tag)
				if j < 0 {
					i = n
				} else {
					i += len(tag) + j + len(tag)
				}
			} else {
				i++
			}
		default:
			i++
		}
	}
	emit(n)
	return out
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

func isIdent(c byte) bool {
	return c == '_' || c == '$' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= 0x80
}

// skipBlock returns the index after the /* ... */ starting at i (nested, as PostgreSQL's)
func skipBlock(s string, i int) int {
	depth := 0
	for i < len(s) {
		switch {
		case s[i] == '/' && i+1 < len(s) && s[i+1] == '*':
			depth++
			i += 2
		case s[i] == '*' && i+1 < len(s) && s[i+1] == '/':
			depth--
			i += 2
			if depth == 0 {
				return i
			}
		default:
			i++
		}
	}
	return i
}

// skipQuote returns the index after the closing quote q (doubled q is a literal q; with esc a
// backslash escapes the next byte)
func skipQuote(s string, i int, q byte, esc bool) int {
	for i < len(s) {
		switch {
		case esc && s[i] == '\\':
			i += 2
		case s[i] == q:
			if i+1 < len(s) && s[i+1] == q {
				i += 2
				continue
			}
			return i + 1
		default:
			i++
		}
	}
	return len(s)
}

// dollarTag: the $tag$ (or $$) that starts at i, if one does
func dollarTag(s string, i int) (string, bool) {
	j := i + 1
	for j < len(s) && s[j] != '$' {
		c := s[j]
		if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= 0x80 || j > i+1 && c >= '0' && c <= '9') {
			return "", false
		}
		j++
	}
	if j >= len(s) {
		return "", false
	}
	return s[i : j+1], true
}

// Words returns the first n words of a statement, skipping white space, comments and opening
// parentheses: keywords lowercased, a quoted identifier unquoted as it is.
func Words(stmt string, n int) []string {
	var w []string
	i := 0
	for i < len(stmt) && len(w) < n {
		c := stmt[i]
		switch {
		case isSpace(c) || c == '(' && len(w) == 0:
			i++
		case c == '-' && i+1 < len(stmt) && stmt[i+1] == '-':
			for i < len(stmt) && stmt[i] != '\n' {
				i++
			}
		case c == '/' && i+1 < len(stmt) && stmt[i+1] == '*':
			i = skipBlock(stmt, i)
		case c == '"':
			j := skipQuote(stmt, i+1, '"', false)
			w = append(w, strings.ReplaceAll(strings.TrimSuffix(stmt[i+1:j], `"`), `""`, `"`))
			i = j
		case isIdent(c) && c != '$':
			j := i
			for j < len(stmt) && isIdent(stmt[j]) {
				j++
			}
			w = append(w, strings.ToLower(stmt[i:j]))
			i = j
		default:
			return w
		}
	}
	return w
}

// allowed: what may start a statement in read-only mode
var allowed = map[string]bool{"select": true, "with": true, "values": true, "table": true, "show": true,
	"explain": true, "set": true, "reset": true}

// settings refused by name: who the session is and whether it may write, and the studio's
// resource scoping of its backend (memory per sort or hash, one process, no JIT, how long it may
// wait for a lock or sit in a transaction; docs/ARCHITECTURE.md "db studio")
var refusedSettings = map[string]bool{"role": true, "session_authorization": true,
	"transaction_read_only": true, "default_transaction_read_only": true,
	"work_mem": true, "hash_mem_multiplier": true, "max_parallel_workers_per_gather": true,
	"max_parallel_workers": true, "temp_buffers": true, "jit": true, "lock_timeout": true,
	"idle_in_transaction_session_timeout": true, "maintenance_work_mem": true,
	"max_parallel_maintenance_workers": true, "logical_decoding_work_mem": true,
	// how a backslash in '...' is read: off, the server and this package's scans would disagree
	// on where a string ends (the scope guard reads names outside strings)
	"standard_conforming_strings": true, "backslash_quote": true}

// refusedCalls: functions a statement may not call by name, though a read-only transaction
// lets them run: set_config would change the settings above from inside a SELECT; the functions
// that run SQL given as text (query_to_xml and its kin, ts_stat, ts_rewrite) would hide such a
// call in a string; pg_cancel_backend and pg_terminate_backend would stop the app's own sessions
// (the same role may signal them); pg_logical_emit_message writes WAL outside the transaction
var refusedCalls = map[string]bool{"set_config": true,
	"query_to_xml": true, "query_to_xmlschema": true, "query_to_xml_and_xmlschema": true,
	"cursor_to_xml": true, "cursor_to_xmlschema": true, "ts_stat": true, "ts_rewrite": true,
	"pg_cancel_backend": true, "pg_terminate_backend": true, "pg_logical_emit_message": true}

// idents calls fn with each identifier of stmt outside quotes and comments (a quoted one
// unquoted, a plain one lowercased as PostgreSQL folds it) and its byte offset, until fn says
// stop. It reports a U&"..." identifier as the word `u&"` (its escapes could spell any name).
// An unterminated dollar quote ends the scan (the server refuses the statement).
func idents(stmt string, fn func(word string, at int) bool) {
	for i := 0; i < len(stmt); {
		c := stmt[i]
		switch {
		case c == '-' && i+1 < len(stmt) && stmt[i+1] == '-':
			for i < len(stmt) && stmt[i] != '\n' {
				i++
			}
		case c == '/' && i+1 < len(stmt) && stmt[i+1] == '*':
			i = skipBlock(stmt, i)
		case c == '\'':
			esc := i > 0 && (stmt[i-1] == 'E' || stmt[i-1] == 'e') && (i < 2 || !isIdent(stmt[i-2]))
			i = skipQuote(stmt, i+1, '\'', esc)
		case c == '$' && (i == 0 || !isIdent(stmt[i-1])):
			if tag, ok := dollarTag(stmt, i); ok {
				j := strings.Index(stmt[i+len(tag):], tag)
				if j < 0 {
					return
				}
				i += len(tag) + j + len(tag)
			} else {
				i++
			}
		case c == '"':
			j := skipQuote(stmt, i+1, '"', false)
			if !fn(strings.ReplaceAll(strings.TrimSuffix(stmt[i+1:j], `"`), `""`, `"`), i) {
				return
			}
			i = j
		case isIdent(c) && c != '$':
			j := i
			for j < len(stmt) && isIdent(stmt[j]) {
				j++
			}
			if j == i+1 && (c == 'u' || c == 'U') && strings.HasPrefix(stmt[j:], `&"`) {
				if !fn(`u&"`, i) { // U&"\0073et_config": PostgreSQL decodes the escapes, this scan would not
					return
				}
			} else if !fn(strings.ToLower(stmt[i:j]), i) {
				return
			}
			i = j
		default:
			i++
		}
	}
}

// calls says whether stmt names one of the refused functions (an identifier outside quotes and
// comments, quoted or not, any case, schema-qualified or not), or has a U&"..." identifier (its
// escapes could spell any of them). A function the app defined that calls set_config is not
// seen: the studio's settings are then a default, not a limit (documented).
func calls(stmt string) bool {
	found := false
	idents(stmt, func(w string, _ int) bool {
		found = w == `u&"` || refusedCalls[strings.ToLower(w)]
		return !found
	})
	return found
}

// ReadOnly says whether stmt may run in read-only mode. It is the accident guard (LOCK, REINDEX,
// ANALYZE, VACUUM, NOTIFY, COMMIT, CALL, DO, COPY ... never reach the server); the boundary is
// PostgreSQL's read-only transaction with a snapshot already taken (srv/studio).
func ReadOnly(stmt string) bool {
	w := Words(stmt, 4)
	if len(w) == 0 || !allowed[w[0]] {
		return false
	}
	if calls(stmt) {
		return false
	}
	if w[0] != "set" && w[0] != "reset" {
		return true
	}
	if w[0] == "reset" { // RESET puts back the session's start values: the studio's own
		return true
	}
	// SET [SESSION | LOCAL] name ...: not TRANSACTION, SESSION CHARACTERISTICS / AUTHORIZATION,
	// ROLE, nor a setting of those
	k := 1
	if len(w) > k && (w[k] == "session" || w[k] == "local") {
		k++
	}
	if len(w) <= k {
		return false
	}
	switch w[k] {
	case "transaction", "session", "role", "characteristics", "authorization":
		return false
	}
	return !refusedSettings[strings.ToLower(w[k])]
}
