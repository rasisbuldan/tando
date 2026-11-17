// Package apps finds the apps on the host and their files under /opt/tando/apps/<app>/.
//
// Layer: internal. It imports internal/kvfile and internal/valid; never a domain package or
// daemon.
package apps

import (
	"os"
	"path/filepath"
	"sort"

	"tando/srv/internal/kvfile"
	"tando/srv/internal/valid"
)

// Dir is root/apps/<app>. app must be valid (valid.App): it becomes a path element.
func Dir(root, app string) string { return filepath.Join(root, "apps", app) }

// Names lists the apps that exist: a directory under root/apps with a regular app.conf (the
// shells' `for f in $R/apps/*/app.conf; [[ -f $f ]]`, symlinks followed) and a valid name.
// Anything else there (a half-destroyed app, a stray directory) is not an app. Sorted by byte.
func Names(root string) ([]string, error) {
	ents, err := os.ReadDir(filepath.Join(root, "apps"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range ents {
		a := e.Name()
		if !valid.App(a) {
			continue
		}
		if fi, err := os.Stat(filepath.Join(root, "apps", a, "app.conf")); err == nil && fi.Mode().IsRegular() {
			names = append(names, a)
		}
	}
	sort.Strings(names)
	return names, nil
}

// Conf reads the app's app.conf (written by the agent: root:tando-m-<app> 640).
func Conf(root, app string) (map[string]string, error) {
	return kvfile.Load(filepath.Join(Dir(root, app), "app.conf"))
}

// State reads the app's state file (current, last_good, phase, ...); empty for a new app.
func State(root, app string) (map[string]string, error) {
	return kvfile.Load(filepath.Join(Dir(root, app), "state"))
}
