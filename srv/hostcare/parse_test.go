package hostcare

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func fixture(t testing.TB, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestParseAptSim(t *testing.T) {
	for _, tt := range []struct {
		file  string
		names []string
		sec   int
	}{
		{"ubuntu24/apt-sim-dist-upgrade.txt", []string{"libc6", "libc-bin"}, 2},
		{"ubuntu26/apt-sim-dist-upgrade.txt", []string{"perl-base", "libc-gconv-modules-extra", "libc6", "libc-bin"}, 4},
	} {
		ps := ParseAptSim(fixture(t, tt.file))
		var names []string
		sec := 0
		for _, p := range ps {
			names = append(names, p.Name)
			if p.Security {
				sec++
			}
		}
		if !slices.Equal(names, tt.names) || sec != tt.sec {
			t.Errorf("%s: %v (%d security)", tt.file, names, sec)
		}
	}
	ps := ParseAptSim(fixture(t, "ubuntu24/apt-sim-dist-upgrade.txt"))
	if p := ps[0]; p.Old != "2.39-0ubuntu8.9" || p.New != "2.39-0ubuntu8.12" || len(p.Origins) != 2 || p.Origins[1] != "Ubuntu:24.04/noble-security" {
		t.Errorf("first: %+v", p)
	}
	// a new package (no old version), an update that is not security, and lines that are not ours
	in := "Inst linux-image-6.8.0-51-generic (6.8.0-51.52 Ubuntu:24.04/noble-updates [amd64])\n" +
		"Inst curl [8.5.0-2ubuntu10.5] (8.5.0-2ubuntu10.6 Ubuntu:24.04/noble-updates [amd64])\n" +
		"Inst -evil [1] (2 x/y-security [amd64])\nInst broken\nInst x [1 (2\nConf curl (8.5)\n"
	ps = ParseAptSim([]byte(in))
	if len(ps) != 2 || ps[0].Old != "" || ps[0].Security || ps[1].Security || ps[1].New != "8.5.0-2ubuntu10.6" {
		t.Errorf("hand: %+v", ps)
	}
}

func TestParseSshdT(t *testing.T) {
	for _, v := range []string{"ubuntu24", "ubuntu26"} {
		s := ParseSshdT(fixture(t, v+"/sshd-T.txt"))
		if !s.Found || !s.Pubkey || s.PermitRoot != "prohibit-password" || !slices.Equal(s.Ports, []int{22}) || s.MaxAuthTries != 6 ||
			!slices.Equal(s.KeyFiles, []string{".ssh/authorized_keys", ".ssh/authorized_keys2"}) || s.EmptyPasswords {
			t.Errorf("%s: %+v", v, s)
		}
		w := ParseSshdT(fixture(t, v+"/sshd-T-weak.txt"))
		if !w.Password || w.PermitRoot != "yes" {
			t.Errorf("%s weak: %+v", v, w)
		}
	}
	if s := ParseSshdT([]byte("garbage\n\x00\nport 99999\nport x\n")); s.Found || len(s.Ports) != 0 {
		t.Errorf("garbage: %+v", s)
	}
}

func TestParseProcNet(t *testing.T) {
	for _, v := range []string{"ubuntu24", "ubuntu26"} {
		tcp := ParseProcNet(fixture(t, v+"/proc-net-tcp.txt"), "tcp")
		tcp6 := ParseProcNet(fixture(t, v+"/proc-net-tcp6.txt"), "tcp")
		var got []string
		for _, s := range append(tcp, tcp6...) {
			got = append(got, s.Addr.String()+" "+itoa(s.Port))
		}
		slices.Sort(got)
		// ss -H -tulpn of the same moment: sshd on 0.0.0.0:22 and [::]:22, python on 0.0.0.0:8765
		if want := []string{"0.0.0.0 22", "0.0.0.0 8765", ":: 22"}; !slices.Equal(got, want) {
			t.Errorf("%s: %v", v, got)
		}
	}
	// loopback in both families, a connected socket (not LISTEN), UDP unconnected
	in := "  sl local rem st\n" +
		"   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 111 1\n" +
		"   1: 0100007F:1F91 0200007F:0016 01 00000000:00000000 00:00000000 00000000 0 0 112 1\n"
	if s := ParseProcNet([]byte(in), "tcp"); len(s) != 1 || !s[0].Addr.IsLoopback() || s[0].Port != 8080 || s[0].Inode != 111 {
		t.Errorf("v4: %+v", s)
	}
	in6 := " sl\n 0: 00000000000000000000000001000000:0035 00000000000000000000000000000000:0000 07 00000000:00000000 00:00000000 00000000 101 0 222 2\n"
	if s := ParseProcNet([]byte(in6), "udp"); len(s) != 1 || s[0].Addr.String() != "::1" || s[0].Port != 53 || s[0].UID != 101 {
		t.Errorf("v6: %+v", s)
	}
}

func TestParseAptConfig(t *testing.T) {
	for _, v := range []string{"ubuntu24", "ubuntu26"} {
		c := ParseAptConfig(fixture(t, v+"/apt-config-dump.txt"))
		// the docker image disables APT::Periodic (docker-disable-periodic-update); a server does not
		if c.Periodic || !c.Enabled || !c.ListsDaily || !c.SecurityOrigin || c.OtherOrigins || c.AutoReboot {
			t.Errorf("%s: %+v", v, c)
		}
	}
	c := ParseAptConfig([]byte(`Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-updates";` + "\n"))
	if !c.OtherOrigins || c.SecurityOrigin || !c.Periodic {
		t.Errorf("updates origin: %+v", c)
	}
}

func TestParseOthers(t *testing.T) {
	n := ParseNeedrestart(fixture(t, "hand/needrestart-svc.txt"))
	if !slices.Equal(n.Services, []string{"cron.service", "ssh.service"}) || n.KernelStatus != 3 || n.KernelExpected != "6.8.0-51-generic" {
		t.Errorf("needrestart: %+v", n)
	}
	if n := ParseNeedrestart(fixture(t, "ubuntu24/needrestart-b.txt")); len(n.Services) != 0 || !n.KernelStatusSet {
		t.Errorf("needrestart 24: %+v", n)
	}
	loc := time.FixedZone("WIB", 7*3600)
	u := ParseUULog(fixture(t, "hand/uu.log"), loc)
	if u.LastRun != time.Date(2026, 11, 16, 6, 10, 1, 0, loc).Unix() || u.LastOK != time.Date(2026, 11, 15, 6, 10, 9, 0, loc).Unix() ||
		u.LastErr <= u.LastOK || !strings.Contains(u.Err, "lock") {
		t.Errorf("uu log: %+v", u)
	}
	h := ParseAptHistory(fixture(t, "hand/history.log"), loc)
	if len(h) != 2 || h[0].By != "unattended-upgrade" || !slices.Equal(h[0].Pkgs, []string{"libc6", "libc-bin"}) ||
		h[1].By != "apt-get" || !slices.Equal(h[1].Pkgs, []string{"curl", "libcurl4t64"}) {
		t.Errorf("history: %+v", h)
	}
	if a := ParseDpkgAudit(fixture(t, "hand/dpkg-audit.txt")); !slices.Equal(a, []string{"libc-bin"}) {
		t.Errorf("audit: %v", a)
	}
	if a := ParseDpkgAudit(fixture(t, "ubuntu26/dpkg-audit.txt")); len(a) != 0 {
		t.Errorf("clean audit: %v", a)
	}
	st := string(fixture(t, "ubuntu24/dpkg-status.txt")) + "\nPackage: jq\nStatus: hold ok installed\nVersion: 8.5\n\n" +
		"Package: linux-image-6.8.0-51-generic\nStatus: install ok installed\nVersion: 1\n\nPackage: linux-image-6.8.0-9-generic\nStatus: install ok installed\n\n" +
		"Package: half\nStatus: install ok half-configured\n\nPackage: gone\nStatus: deinstall ok config-files\n"
	d := ParseDpkgStatus([]byte(st), "jq", "nothere")
	if !slices.Contains(d.Held, "jq") || d.Installed["jq"] != "8.5" || !slices.Equal(d.Kernels, []string{"6.8.0-9-generic", "6.8.0-51-generic"}) ||
		!slices.Equal(d.Broken, []string{"half (half-configured)"}) || d.Packages < 10 {
		t.Errorf("dpkg: held %v kernels %v broken %v n %d", d.Held, d.Kernels, d.Broken, d.Packages)
	}
	if p := ParsePSI(fixture(t, "hand/psi-memory")); !p.Known || p.Some60 != 31.2 || p.Full60 != 2 {
		t.Errorf("psi: %+v", p)
	}
	if p := ParsePSI(nil); p.Known {
		t.Error("no PSI file is unknown")
	}
	rules := ParseUfwRules(fixture(t, "hand/user.rules"))
	fw := Firewall{Ufw: true, UfwDeny: true, Rules: rules}
	for _, c := range []struct {
		proto string
		port  int
		want  string
	}{{"tcp", 22, "no"}, {"tcp", 443, "no"}, {"tcp", 60500, "no"}, {"tcp", 5432, "yes"}, {"tcp", 3306, "yes"}, {"udp", 443, "yes"}} {
		if got := fw.Blocks(c.proto, c.port); got != c.want {
			t.Errorf("ufw %s/%d: %s", c.proto, c.port, got)
		}
	}
	if !fw.Limits(22) || fw.Limits(80) {
		t.Error("ufw limit 22")
	}
	drop, chain := ParseNftChains(fixture(t, "hand/nftables.conf"))
	if !drop || !chain || (Firewall{NftDrop: true}).Blocks("tcp", 5432) != "unknown" || (Firewall{}).Blocks("tcp", 1) != "no" {
		t.Error("nftables")
	}
	ms := ParseMounts([]byte("/dev/sda1 / ext4 rw,relatime 0 0\n/dev/sdb1 /data\\040x ext4 ro,relatime 0 0\n"))
	if len(ms) != 2 || ms[1].Dir != "/data x" || !ms[1].ro() || ms[0].ro() || mountOf(ms, "/data x/y") != "/data x" || mountOf(ms, "/var") != "/" {
		t.Errorf("mounts: %+v", ms)
	}
	if got := ParseFailedUnits([]byte("foo.service loaded failed failed Foo\n● bar.timer loaded failed failed Bar\nnot a unit\n")); !slices.Equal(got, []string{"foo.service", "bar.timer"}) {
		t.Errorf("failed units: %v", got)
	}
	if u := unitOfCgroup([]byte("0::/system.slice/caddy.service\n")); u != "caddy.service" {
		t.Errorf("cgroup: %q", u)
	}
	if u := unitOfCgroup([]byte("0::/user.slice/user-1000.slice/session-3.scope\n")); u != "session-3.scope" {
		t.Errorf("cgroup scope: %q", u)
	}
	if !otherSites([]byte("example.com {\n\treverse_proxy :3000\n}\nimport /etc/caddy/tando/*.caddy\n")) ||
		otherSites([]byte("{\n\tadmin off\n}\n:80 {\n\troot * /usr/share/caddy\n}\n# a.com {\nimport /etc/caddy/tando/*.caddy\n")) {
		t.Error("caddy_ours rule")
	}
	if cpusOnline("0-3,5") != 5 || cpusOnline("0") != 1 || cpusOnline("") != 0 {
		t.Error("cpus")
	}
}

func TestJournalEvents(t *testing.T) {
	es := ParseJournal(fixture(t, "hand/journal.json"), 100)
	kinds := map[string]int{}
	ssh := 0
	for _, e := range es {
		if e.Transport == "kernel" {
			kinds[KernelEvent(e.Message)]++
		}
		if (e.Ident == "sshd" || e.Ident == "sshd-session") && SSHFailure(e.Message) {
			ssh++
		}
	}
	if len(es) != 7 || kinds["ioerr"] != 2 || kinds["oom"] != 1 || ssh != 2 {
		t.Errorf("%d entries, kinds %v, ssh %d", len(es), kinds, ssh)
	}
	if c := lastCursor(fixture(t, "hand/journal.json")); c != "s=1;i=8" {
		t.Errorf("cursor %q", c)
	}
}

func TestSortVersions(t *testing.T) {
	v := []string{"6.8.0-51-generic", "6.11.0-9-generic", "6.8.0-49-generic", "6.8.0-100-generic", "5.15.0-1-generic"}
	SortVersions(v)
	if want := []string{"5.15.0-1-generic", "6.8.0-49-generic", "6.8.0-51-generic", "6.8.0-100-generic", "6.11.0-9-generic"}; !slices.Equal(v, want) {
		t.Errorf("%v", v)
	}
}

func TestEOL(t *testing.T) {
	for _, c := range []struct {
		id, v string
		ok    bool
		day   string
	}{{"ubuntu", "24.04", true, "2029-05-31"}, {"ubuntu", "26.04", true, "2031-05-31"}, {"ubuntu", "20.04", true, "2025-05-29"},
		{"ubuntu", "26.10", false, ""}, {"debian", "12", false, ""}, {"ubuntu", "", false, ""}} {
		e, ok := EOL(c.id, c.v)
		if ok != c.ok || (ok && e.Format("2006-01-02") != c.day) {
			t.Errorf("%s %s: %v %v", c.id, c.v, e, ok)
		}
	}
	for v, d := range eolTable { // every date parses
		if _, err := time.Parse("2006-01-02", d); err != nil {
			t.Errorf("%s: %v", v, err)
		}
	}
}

// the parsers never panic and return bounded, cleanable values whatever they are given
func FuzzParsers(f *testing.F) {
	for _, n := range []string{"ubuntu24/apt-sim-dist-upgrade.txt", "ubuntu26/sshd-T.txt", "ubuntu24/proc-net-tcp.txt", "hand/journal.json",
		"hand/uu.log", "hand/history.log", "hand/user.rules", "hand/needrestart-svc.txt", "ubuntu26/apt-config-dump.txt", "hand/psi-memory"} {
		f.Add(fixture(f, n))
	}
	f.Add([]byte("Inst a [ (\nInst ab [1] (2 x/-security, , [\n\x00\xff\n"))
	loc := time.UTC
	f.Fuzz(func(t *testing.T, b []byte) {
		ParseAptSim(b)
		ParseSshdT(b)
		ParseProcNet(b, "tcp")
		ParseProcNet(b, "udp")
		ParseJournal(b, 1000)
		ParseUULog(b, loc)
		ParseAptHistory(b, loc)
		ParseUfwRules(b)
		ParseNeedrestart(b)
		ParseAptConfig(b)
		ParsePSI(b)
		ParseMounts(b)
		ParseDpkgStatus(b, "x")
		ParseDpkgAudit(b)
		ParseFailedUnits(b)
		ParseNftChains(b)
		ParseOSRelease(b)
		unitOfCgroup(b)
		otherSites(b)
		for _, p := range ParseAptSim(b) {
			if !pkgName(p.Name) || strings.HasPrefix(p.Name, "-") {
				t.Fatalf("bad name %q", p.Name)
			}
		}
	})
}
