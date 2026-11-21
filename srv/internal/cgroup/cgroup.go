// Package cgroup reads the cgroup v2 files of an app's unit (memory.stat, cpu.stat,
// memory.events). Reading needs no root and starts no process.
//
// Layer: internal: the standard library only; never a domain package or daemon.
package cgroup

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// AppDir is the cgroup directory of tando-<app>.service under root (/sys/fs/cgroup). Apps run in
// their own slice, tando.slice/tando-<app>.slice, whose name systemd escapes ("-" is a level
// separator in slice names, so hello-2's slice is tando-hello\x2d2.slice and not under hello's);
// apps set up before the per-app slices are still under system.slice until their next deploy.
func AppDir(root, app string) string {
	d := filepath.Join(root, "tando.slice", "tando-"+strings.ReplaceAll(app, "-", `\x2d`)+".slice", "tando-"+app+".service")
	if fi, err := os.Stat(d); err == nil && fi.IsDir() {
		return d
	}
	return filepath.Join(root, "system.slice", "tando-"+app+".service")
}

// Sum is the total of keys in a flat keyed file (memory.stat: "anon", "shmem"); 0 for a file that
// cannot be read or keys it lacks.
func Sum(file string, keys ...string) int64 {
	f, err := os.Open(file)
	if err != nil {
		return 0
	}
	defer f.Close()
	var n int64
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), " ")
		if !ok {
			continue
		}
		for _, want := range keys {
			if k == want {
				if x, err := strconv.ParseInt(v, 10, 64); err == nil {
					n += x
				}
			}
		}
	}
	return n
}

// Value is key's number in a flat-keyed file ("anon 1234" lines: memory.stat, cpu.stat,
// memory.events), and whether it was there. A missing or unreadable file (the unit is not
// running) is "not there", like a key that is absent.
func Value(file, key string) (int64, bool) {
	f, err := os.Open(file)
	if err != nil {
		return 0, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), " ")
		if ok && k == key {
			n, err := strconv.ParseInt(v, 10, 64)
			return n, err == nil
		}
	}
	return 0, false
}
