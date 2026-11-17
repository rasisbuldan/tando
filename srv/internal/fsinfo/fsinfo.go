// Package fsinfo says what a path is (a directory, a regular file, anything) and how full its
// file system is (statfs, as df counts it), without starting a program.
//
// Whether a check follows a symbolic link is part of every name here, so each call site says it:
// NoFollow (lstat) wherever the path is in a directory a user other than root can write (an app's
// Caddy log directory, a deploy user's /run/user/<uid>, an upload): such a user can put a link
// there, and the answer must be about what is there, not about where it points. Follow (stat)
// where the directory is root's (/opt/tando, /var/lib/tando, /etc, /proc) and the shell version
// followed links ([[ -d ]], [[ -f ]]).
//
// A leaf: standard library only (tando-gate links it).
package fsinfo

import "os"

// DirFollow: path is a directory or a link to one ([[ -d $p ]]).
func DirFollow(p string) bool { fi, err := os.Stat(p); return err == nil && fi.IsDir() }

// DirNoFollow: path is a directory itself, not a link.
func DirNoFollow(p string) bool { fi, err := os.Lstat(p); return err == nil && fi.IsDir() }

// RegularFollow: path is a regular file or a link to one ([[ -f $p ]]).
func RegularFollow(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

// RegularNoFollow: path is a regular file itself, not a link.
func RegularNoFollow(p string) bool {
	fi, err := os.Lstat(p)
	return err == nil && fi.Mode().IsRegular()
}

// ExistsFollow: path exists, a link only when its target does ([[ -e $p ]]).
func ExistsFollow(p string) bool { _, err := os.Stat(p); return err == nil }

// ExistsNoFollow: something is at path, a dangling link too.
func ExistsNoFollow(p string) bool { _, err := os.Lstat(p); return err == nil }
