package status

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseMemoryMax(t *testing.T) {
	for _, c := range []struct {
		in, want string
		ok       bool
	}{
		{"[Service]\nMemoryMax=128M\n", "134217728", true},
		{"[Unit]\nDescription=x\n[Service]\nMemoryMax=1G\nMemoryMax = 64M \n", "67108864", true},
		{"[Service]\nMemoryMax=512K\r\n", "524288", true},
		{"[Service]\nMemoryMax=2T\n", "2199023255552", true},
		{"[Service]\nMemoryMax=1000\n", "1000", true},
		{"[Service]\nMemoryMax=infinity\n", "", true},
		{"[Service]\nMemoryMax=128M\nMemoryMax=\n", "", true},
		{"[Service]\nExecStart=/bin/true\n", "", true},
		{"# MemoryMax=1G\n[Service]\n; MemoryMax=2G\n", "", true},
		{"[Service]\nMemoryMax=1.5G\n", "", false},
		{"[Service]\nMemoryMax=50%\n", "", false},
		{"[Service]\nMemoryMax=128m\n", "", false},
		{"[Service]\nMemoryLimit=128M\n", "", false},
		{"[Service]\nEnvironment=A=1 \\\n  MemoryMax=1\n", "", false},
		{"[Install]\nMemoryMax=128M\n", "", false},
	} {
		got, ok := parseMemoryMax(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("%q: %q %v, want %q %v", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestMemoryMaxFromFile(t *testing.T) {
	root := t.TempDir()
	w := func(p, s string) {
		os.MkdirAll(filepath.Dir(filepath.Join(root, p)), 0o755)
		os.WriteFile(filepath.Join(root, p), []byte(s), 0o644)
	}
	w("etc/systemd/system/tando-web.service", "[Service]\nMemoryMax=128M\n")
	check := func(unit, want string, wantOK bool) {
		t.Helper()
		got, ok := memoryMaxFromFile(root, unit)
		if got != want || ok != wantOK {
			t.Errorf("%s: %q %v, want %q %v", unit, got, ok, want, wantOK)
		}
	}
	check("tando-web.service", "134217728", true)
	check("tando-none.service", "", false) // no file: not-found, systemd says (infinity)
	check("tando-web.socket", "", false)   // only services
	check("tando-x@1.service", "", false)  // templates: not here
	w("etc/systemd/system/tando-hello-2.service", "[Service]\nMemoryMax=64M\n")
	check("tando-hello-2.service", "67108864", true)
	w("usr/lib/systemd/system/tando-hello-.service.d/x.conf", "[Service]\nMemoryMax=1G\n")
	check("tando-hello-2.service", "", false) // a dash-prefix drop-in applies
	w("run/systemd/system/tando-web.service.d/override.conf", "[Service]\nMemoryMax=1G\n")
	check("tando-web.service", "", false)
	os.RemoveAll(filepath.Join(root, "run/systemd/system/tando-web.service.d"))
	check("tando-web.service", "134217728", true)
	w("etc/systemd/system.control/tando-web.service", "[Service]\nMemoryMax=1G\n") // higher priority
	check("tando-web.service", "", false)
	os.Remove(filepath.Join(root, "etc/systemd/system.control/tando-web.service"))
	w("usr/lib/systemd/system/tando-web.service", "[Service]\n") // a second file: asked
	check("tando-web.service", "", false)
	os.Remove(filepath.Join(root, "usr/lib/systemd/system/tando-web.service"))
	os.Remove(filepath.Join(root, "etc/systemd/system/tando-web.service"))
	os.Symlink("/dev/null", filepath.Join(root, "etc/systemd/system/tando-web.service")) // masked
	check("tando-web.service", "", false)
	w("etc/systemd/system/service.d/all.conf", "[Service]\nTasksMax=10\n")
	w("etc/systemd/system/tando-b.service", "[Service]\nMemoryMax=128M\n")
	check("tando-b.service", "", false)
}
