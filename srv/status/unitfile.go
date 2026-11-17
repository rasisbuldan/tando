package status

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"tando/srv/internal/decimal"
)

// unitDirs are the system manager's unit search path, highest priority first (systemd's
// lookup_paths for the system instance, with /lib for a split /usr).
func unitDirs() []string {
	return []string{
		"/etc/systemd/system.control", "/run/systemd/system.control", "/run/systemd/transient",
		"/run/systemd/generator.early", "/etc/systemd/system", "/etc/systemd/system.attached",
		"/run/systemd/system", "/run/systemd/system.attached", "/run/systemd/generator",
		"/usr/local/lib/systemd/system", "/usr/lib/systemd/system", "/lib/systemd/system",
		"/run/systemd/generator.late",
	}
}

// fragmentDir is where tando writes app units; only a unit whose file is there alone counts.
const fragmentDir = "/etc/systemd/system"

// maxUnitFile bounds the read of a unit file.
const maxUnitFile = 256 << 10

// memoryMaxFromFile is the MemoryMax systemd would report for a unit that is not loaded (it
// would load it from its file to answer, which costs it a parse and a garbage collection),
// read from the file itself: when the unit's only file is a regular file in /etc/systemd/system
// (tando writes app units there), no drop-in directory applies to it anywhere on the search path
// (<unit>.d, the dash-prefix ones, service.d), and the value is one systemd and this agree on
// (infinity, or a whole number with an optional K, M, G or T: base 1024). Otherwise false, and
// systemd is asked. "" is infinity, as from the bus.
func memoryMaxFromFile(root, unit string) (string, bool) {
	if !strings.HasSuffix(unit, ".service") || strings.ContainsAny(unit, "/\\@") {
		return "", false
	}
	base := strings.TrimSuffix(unit, ".service")
	dropins := []string{unit + ".d", "service.d"}
	// dash prefixes: tando-hello-2.service also takes tando-.service.d and tando-hello-.service.d
	for i := 0; i < len(base); i++ {
		if base[i] == '-' {
			dropins = append(dropins, base[:i+1]+".service.d")
		}
	}
	frag := ""
	for _, d := range unitDirs() {
		d = filepath.Join(root, d)
		for _, x := range dropins {
			if _, err := os.Lstat(filepath.Join(d, x)); err == nil {
				return "", false
			}
		}
		p := filepath.Join(d, unit)
		fi, err := os.Lstat(p)
		if err != nil {
			continue
		}
		if frag != "" || d != filepath.Join(root, fragmentDir) || !fi.Mode().IsRegular() {
			return "", false // another file, a higher-priority one, a link (alias or mask)
		}
		frag = p
	}
	if frag == "" {
		return "", false
	}
	b, err := readBounded(frag, maxUnitFile, true)
	if err != nil {
		return "", false
	}
	return parseMemoryMax(string(b))
}

// parseMemoryMax finds the [Service] MemoryMax= of a unit file (the last one wins; an empty one
// resets to infinity) and reads it; false for anything this does not read as systemd does
// (continuation lines, MemoryLimit=, a fraction, a percentage, an unknown suffix).
func parseMemoryMax(text string) (string, bool) {
	section := ""
	val, set := "", false
	for _, l := range strings.Split(text, "\n") {
		l = strings.TrimSpace(strings.TrimSuffix(l, "\r"))
		if l == "" || l[0] == '#' || l[0] == ';' {
			continue
		}
		if strings.HasSuffix(l, "\\") {
			return "", false
		}
		if l[0] == '[' {
			section = l
			continue
		}
		k, v, ok := strings.Cut(l, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		if section != "[Service]" && (k == "MemoryMax" || k == "MemoryLimit") {
			return "", false
		}
		switch k {
		case "MemoryLimit":
			return "", false
		case "MemoryMax":
			val, set = strings.TrimSpace(v), true
		}
	}
	if !set || val == "" || val == "infinity" {
		return "", true
	}
	mult := uint64(1)
	switch val[len(val)-1] {
	case 'K':
		mult = 1 << 10
	case 'M':
		mult = 1 << 20
	case 'G':
		mult = 1 << 30
	case 'T':
		mult = 1 << 40
	}
	num := val
	if mult > 1 {
		num = val[:len(val)-1]
	}
	if !decimal.IsDigits(num) || len(num) > 12 {
		return "", false
	}
	n, err := strconv.ParseUint(num, 10, 64)
	if err != nil {
		return "", false
	}
	return strconv.FormatUint(n*mult, 10), true
}
