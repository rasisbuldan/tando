// Package kvfile reads and writes tando's key=value files (app.conf, state, host.conf,
// alerts.conf, activation, ...). Values are data only: never evaluated, never sourced.
//
// Layer: internal. It imports internal/atomicfile and internal/bashread (the line rules); never a
// domain package or daemon.
package kvfile

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"slices"
	"strings"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
)

// Parse reads key=value lines. Each line is split at its first "=" (so a value keeps a trailing
// "=", which `IFS='=' read` would drop). Lines without "=", an empty key, or a key starting
// with "#" (a comment that happens to contain "=") are skipped; of duplicate keys the last wins.
// A last line without a newline counts; a "\r" is part of the value, as in bash.
func Parse(r io.Reader) (map[string]string, error) {
	b, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	m := map[string]string{}
	kv := bashread.KV{Data: string(b), Partial: true, SkipComments: true}
	for k, v, ok := kv.Next(); ok; k, v, ok = kv.Next() {
		m[k] = v
	}
	return m, nil
}

// Load parses the file at path. A missing file is an empty map, as in the shell programs
// (`[[ -r $f ]] || return 0`): a new app has no state yet.
func Load(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	m, err := Parse(f)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return m, nil
}

// Format renders m as key=value lines sorted by key, so the same map always gives the same bytes
// (WriteIfChanged can then skip an unchanged file). Keys and values must not hold a newline, and
// keys no "=": both would change the file's meaning when read back, so Format refuses them.
func Format(m map[string]string) ([]byte, error) {
	var b bytes.Buffer
	for _, k := range slices.Sorted(maps.Keys(m)) {
		v := m[k]
		if k == "" || strings.ContainsAny(k, "=\n") || strings.Contains(v, "\n") {
			return nil, fmt.Errorf("key=value: refusing key %q (value %q)", k, v)
		}
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(v)
		b.WriteByte('\n')
	}
	return b.Bytes(), nil
}

// Save writes m to path atomically with the given mode and owner, only when it changed;
// it reports whether it wrote.
func Save(path string, m map[string]string, p atomicfile.Perm) (bool, error) {
	data, err := Format(m)
	if err != nil {
		return false, fmt.Errorf("write %s: %w", path, err)
	}
	return atomicfile.WriteIfChanged(path, data, p)
}
