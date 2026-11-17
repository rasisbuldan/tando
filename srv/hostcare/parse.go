package hostcare

// The parsers: bytes in, values out. No files, no commands, no clock (a time zone is passed in
// where text carries local times). Everything they return is still untrusted text (package and
// unit names, process names, journal lines): it is cleaned where it leaves the package (clean,
// out.Writer). Each has a table test against output captured on Ubuntu 24.04 and 26.04
// (testdata/) and a fuzz target.

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/decimal"
)

// Pkg is one package apt would install or upgrade (`apt-get -s dist-upgrade`, LC_ALL=C).
type Pkg struct {
	Name, Old, New string
	Origins        []string // "Ubuntu:24.04/noble-security", ...
	Security       bool     // one of its origins is a -security pocket
}

// ParseAptSim reads the "Inst" lines of `apt-get -s dist-upgrade`:
//
//	Inst libc6 [2.39-0ubuntu8.9] (2.39-0ubuntu8.12 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [arm64])
//	Inst linux-image-6.8.0-51-generic (6.8.0-51.52 Ubuntu:24.04/noble-updates [amd64])
//
// (a new package has no [old version]). Only these lines are read: under LC_ALL=C apt's other
// words do not matter, and in another language the Inst lines are the same (they are not
// translated), so a missing LC_ALL loses nothing. Lines that do not have this shape are skipped.
func ParseAptSim(b []byte) []Pkg {
	var res []Pkg
	for _, l := range lines(b, 20000) {
		rest, ok := strings.CutPrefix(l, "Inst ")
		if !ok {
			continue
		}
		name, rest, _ := strings.Cut(rest, " ")
		if name == "" || !pkgName(name) {
			continue
		}
		p := Pkg{Name: name}
		if strings.HasPrefix(rest, "[") {
			old, r, ok := strings.Cut(rest[1:], "] ")
			if !ok {
				continue
			}
			p.Old, rest = old, r
		}
		if !strings.HasPrefix(rest, "(") {
			continue
		}
		in, _, ok := strings.Cut(rest[1:], ")")
		if !ok {
			continue
		}
		// "<version> <origin>, <origin> [<arch>]"
		if i := strings.LastIndex(in, " ["); i >= 0 {
			in = in[:i]
		}
		ver, origins, _ := strings.Cut(in, " ")
		p.New = ver
		for _, o := range strings.Split(origins, ", ") {
			if o = strings.TrimSpace(o); o == "" {
				continue
			}
			p.Origins = append(p.Origins, o)
			// (the distribution's own archive only: any repository may name a suite "-security")
			if from, suite, ok := strings.Cut(o, "/"); ok && strings.HasSuffix(suite, "-security") && (strings.HasPrefix(from, "Ubuntu") || strings.HasPrefix(from, "Debian")) {
				p.Security = true
			}
		}
		res = append(res, p)
	}
	return res
}

// pkgName: Debian package names (and apt's ":arch" suffix): [a-z0-9][a-z0-9+.-]+.
func pkgName(s string) bool {
	if len(s) < 2 || len(s) > 120 || !(s[0] >= 'a' && s[0] <= 'z' || s[0] >= '0' && s[0] <= '9') {
		return false // (never starts with "-": a name can be a program's argument)
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '+' || c == '.' || c == '-' || c == ':' || (c >= 'A' && c <= 'Z')) {
			return false
		}
	}
	return true
}

// lines splits b into at most max lines (a last line without a newline counts), each cut to
// 4096 bytes: a bound for text from programs and files tando does not control.
func lines(b []byte, max int) []string {
	var res []string
	for len(b) > 0 && len(res) < max {
		i := bytes.IndexByte(b, '\n')
		var l []byte
		if i < 0 {
			l, b = b, nil
		} else {
			l, b = b[:i], b[i+1:]
		}
		if len(l) > 4096 {
			l = l[:4096]
		}
		res = append(res, strings.TrimRight(string(l), "\r"))
	}
	return res
}

// ParseOSRelease reads /etc/os-release (KEY=value, values optionally quoted).
func ParseOSRelease(b []byte) map[string]string {
	m := map[string]string{}
	for _, l := range lines(b, 200) {
		k, v, ok := strings.Cut(l, "=")
		if !ok || k == "" || strings.HasPrefix(k, "#") {
			continue
		}
		if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
			v = v[1 : len(v)-1]
		}
		m[k] = v
	}
	return m
}

// SSHD is what `sshd -T` (the effective configuration, as root) says about how one logs in.
type SSHD struct {
	Password, KbdInteractive, Pubkey, EmptyPasswords bool
	PermitRoot                                       string // yes, no, prohibit-password, forced-commands-only
	MaxAuthTries                                     int
	Ports                                            []int
	KeyFiles                                         []string // authorizedkeysfile patterns (%h, %u)
	Found                                            bool     // the output had the keys at all
}

// ParseSshdT reads `sshd -T`: one "keyword value" per line, keywords in lower case.
func ParseSshdT(b []byte) SSHD {
	s := SSHD{PermitRoot: "", MaxAuthTries: 6}
	for _, l := range lines(b, 2000) {
		k, v, _ := strings.Cut(l, " ")
		v = strings.TrimSpace(v)
		switch k {
		case "passwordauthentication":
			s.Password, s.Found = v == "yes", true
		case "kbdinteractiveauthentication", "challengeresponseauthentication":
			s.KbdInteractive = s.KbdInteractive || v == "yes"
		case "pubkeyauthentication":
			s.Pubkey = v == "yes"
		case "permitemptypasswords":
			s.EmptyPasswords = v == "yes"
		case "permitrootlogin":
			if s.PermitRoot = v; v == "without-password" { // (the older name, OpenSSH before 7.0's default)
				s.PermitRoot = "prohibit-password"
			}
		case "maxauthtries":
			if n, ok := decimal.Parse(v, 4); ok {
				s.MaxAuthTries = int(n)
			}
		case "port":
			if n, ok := decimal.Parse(v, 5); ok && n > 0 && n < 65536 {
				s.Ports = append(s.Ports, int(n))
			}
		case "authorizedkeysfile":
			s.KeyFiles = append(s.KeyFiles, strings.Fields(v)...)
		}
	}
	return s
}

// Socket is one listening socket of /proc/net/{tcp,tcp6,udp,udp6}.
type Socket struct {
	Proto string // tcp, udp
	Addr  netip.Addr
	Port  int
	UID   int
	Inode uint64
}

// ParseProcNet reads one of /proc/net/{tcp,udp}[6] and returns the listening sockets: TCP in
// state LISTEN (0A), UDP unconnected (07) with a local port. Addresses are hex in the kernel's
// byte order (little endian per 32-bit word on the machines tando runs on).
func ParseProcNet(b []byte, proto string) []Socket {
	var res []Socket
	for i, l := range lines(b, 100000) {
		if i == 0 {
			continue // the header
		}
		f := strings.Fields(l)
		if len(f) < 10 {
			continue
		}
		st := f[3]
		if (proto == "tcp" && st != "0A") || (proto == "udp" && st != "07") {
			continue
		}
		ha, hp, ok := strings.Cut(f[1], ":")
		if !ok {
			continue
		}
		port, err := strconv.ParseUint(hp, 16, 16)
		if err != nil || port == 0 {
			continue
		}
		addr, ok := procAddr(ha)
		if !ok {
			continue
		}
		uid, _ := decimal.Parse(f[7], 10)
		ino, err := strconv.ParseUint(f[9], 10, 64)
		if err != nil {
			continue
		}
		res = append(res, Socket{Proto: proto, Addr: addr, Port: int(port), UID: int(uid), Inode: ino})
	}
	return res
}

// procAddr decodes the kernel's hex address: 8 hex digits (IPv4) or 32 (IPv6), each 32-bit word
// in host byte order (little endian on amd64 and arm64).
func procAddr(h string) (netip.Addr, bool) {
	raw, err := hex.DecodeString(h)
	if err != nil || (len(raw) != 4 && len(raw) != 16) {
		return netip.Addr{}, false
	}
	for i := 0; i+4 <= len(raw); i += 4 {
		raw[i], raw[i+1], raw[i+2], raw[i+3] = raw[i+3], raw[i+2], raw[i+1], raw[i]
	}
	if len(raw) == 4 {
		return netip.AddrFrom4([4]byte(raw)), true
	}
	return netip.AddrFrom16([16]byte(raw)).Unmap(), true
}

// PSI is a line of /proc/pressure/<resource>: the share of time tasks were stalled.
type PSI struct {
	Some10, Some60, Full60 float64
	Known                  bool
}

// ParsePSI reads /proc/pressure/{memory,cpu,io}.
func ParsePSI(b []byte) PSI {
	var p PSI
	for _, l := range lines(b, 4) {
		kind, rest, _ := strings.Cut(l, " ")
		for _, kv := range strings.Fields(rest) {
			k, v, _ := strings.Cut(kv, "=")
			x, err := strconv.ParseFloat(v, 64)
			if err != nil {
				continue
			}
			switch kind + "." + k {
			case "some.avg10":
				p.Some10, p.Known = x, true
			case "some.avg60":
				p.Some60, p.Known = x, true
			case "full.avg60":
				p.Full60 = x
			}
		}
	}
	return p
}

// ParseMeminfo reads /proc/meminfo into kB values.
func ParseMeminfo(b []byte) map[string]int64 {
	m := map[string]int64{}
	for _, l := range lines(b, 200) {
		f := strings.Fields(l)
		if len(f) < 2 {
			continue
		}
		if n, ok := decimal.Parse(f[1], 15); ok {
			m[strings.TrimSuffix(f[0], ":")] = n
		}
	}
	return m
}

// Mount is one line of /proc/mounts (or /etc/fstab).
type Mount struct {
	Dev, Dir, Type string
	Opts           []string
}

func (m Mount) ro() bool {
	for _, o := range m.Opts {
		if o == "ro" {
			return true
		}
	}
	return false
}

// ParseMounts reads /proc/mounts or /etc/fstab ("\040" stands for a space in either).
func ParseMounts(b []byte) []Mount {
	var res []Mount
	for _, l := range lines(b, 5000) {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		f := strings.Fields(l)
		if len(f) < 4 {
			continue
		}
		res = append(res, Mount{Dev: unoctal(f[0]), Dir: unoctal(f[1]), Type: f[2], Opts: strings.Split(f[3], ",")})
	}
	return res
}

// unoctal turns the kernel's \ooo escapes back into bytes.
func unoctal(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) {
			if n, err := strconv.ParseUint(s[i+1:i+4], 8, 8); err == nil {
				b.WriteByte(byte(n))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// Needrestart is what `needrestart -b` (batch mode) says.
type Needrestart struct {
	Services        []string // units that run old code
	KernelCurrent   string
	KernelExpected  string
	KernelStatus    int // 0 unknown, 1 current, 2 ABI-compatible upgrade pending, 3 version upgrade pending
	KernelStatusSet bool
}

// ParseNeedrestart reads `needrestart -b` (NEEDRESTART-SVC: unit lines and the kernel's).
func ParseNeedrestart(b []byte) Needrestart {
	var n Needrestart
	for _, l := range lines(b, 2000) {
		k, v, ok := strings.Cut(l, ": ")
		if !ok {
			continue
		}
		v = strings.TrimSpace(v)
		switch k {
		case "NEEDRESTART-SVC":
			if v != "" && len(n.Services) < 200 {
				n.Services = append(n.Services, v)
			}
		case "NEEDRESTART-KCUR":
			n.KernelCurrent = v
		case "NEEDRESTART-KEXP":
			n.KernelExpected = v
		case "NEEDRESTART-KSTA":
			if x, ok := decimal.Parse(v, 1); ok {
				n.KernelStatus, n.KernelStatusSet = int(x), true
			}
		}
	}
	return n
}

// UULog is what the log of unattended-upgrades says about its last runs.
type UULog struct {
	LastRun, LastOK, LastErr int64  // epochs (0: never)
	Err                      string // the last error line's text
}

// ParseUULog reads /var/log/unattended-upgrades/unattended-upgrades.log (its tail): lines
// "2026-11-17 06:12:01,123 INFO Starting unattended upgrades script", in the server's local
// time (loc). A run ends well with "All upgrades installed" or "No packages found that can be
// upgraded unattended..."; an ERROR line (or "Installing the upgrades failed!") is a failure.
func ParseUULog(b []byte, loc *time.Location) UULog {
	var u UULog
	for _, l := range lines(b, 50000) {
		if len(l) < 24 || l[4] != '-' || l[10] != ' ' {
			continue
		}
		t, err := time.ParseInLocation("2006-01-02 15:04:05", l[:19], loc)
		if err != nil {
			continue
		}
		ts := t.Unix()
		rest := l[19:]
		if i := strings.IndexByte(rest, ' '); i >= 0 {
			rest = rest[i+1:]
		}
		level, msg, _ := strings.Cut(rest, " ")
		switch {
		case strings.HasPrefix(msg, "Starting unattended upgrades script"):
			u.LastRun = ts
		case strings.HasPrefix(msg, "All upgrades installed"), strings.HasPrefix(msg, "No packages found that can be upgraded unattended"):
			u.LastOK = ts
		case level == "ERROR", strings.Contains(msg, "Installing the upgrades failed"):
			u.LastErr, u.Err = ts, msg
		}
	}
	return u
}

// Upgrade is one apt run that installed or upgraded packages (/var/log/apt/history.log).
type Upgrade struct {
	At   int64
	By   string // the command: unattended-upgrade, apt-get, apt, ...
	Pkgs []string
}

// ParseAptHistory reads /var/log/apt/history.log (its tail): blocks of "Start-Date:",
// "Commandline:", "Upgrade:"/"Install:" (pkg:arch (old, new), ...), "End-Date:", in local time.
func ParseAptHistory(b []byte, loc *time.Location) []Upgrade {
	var res []Upgrade
	var cur *Upgrade
	for _, l := range lines(b, 50000) {
		k, v, ok := strings.Cut(l, ": ")
		if !ok {
			continue
		}
		switch k {
		case "Start-Date":
			t, err := time.ParseInLocation("2006-01-02  15:04:05", v, loc)
			if err != nil {
				cur = nil
				continue
			}
			res = append(res, Upgrade{At: t.Unix()})
			cur = &res[len(res)-1]
		case "Commandline":
			if cur != nil {
				f := strings.Fields(v)
				if len(f) > 0 {
					cur.By = f[0][strings.LastIndexByte(f[0], '/')+1:]
				}
			}
		case "Upgrade", "Install":
			if cur == nil {
				continue
			}
			// "libc6:arm64 (2.39-0ubuntu8.9, 2.39-0ubuntu8.12), libc-bin:arm64 (...)"
			depth, start := 0, 0
			for i := 0; i <= len(v); i++ {
				if i < len(v) {
					switch v[i] {
					case '(':
						depth++
						continue
					case ')':
						depth--
						continue
					case ',':
						if depth > 0 {
							continue
						}
					default:
						continue
					}
				}
				item := strings.TrimSpace(v[start:i])
				start = i + 1
				name, _, _ := strings.Cut(item, " ")
				name, _, _ = strings.Cut(name, ":")
				if pkgName(name) && len(cur.Pkgs) < 500 {
					cur.Pkgs = append(cur.Pkgs, name)
				}
			}
		}
	}
	out := res[:0]
	for _, u := range res {
		if len(u.Pkgs) > 0 {
			out = append(out, u)
		}
	}
	return out
}

// Dpkg is what /var/lib/dpkg/status says, in the parts host care uses.
type Dpkg struct {
	Held       []string          // "Status: hold ..." (apt-mark hold)
	Broken     []string          // installed but not "ok installed": half-configured, unpacked, ...
	Installed  map[string]string // name -> version, for the packages asked for
	Kernels    []string          // installed linux-image-<version> packages: the versions
	Packages   int               // installed packages
	Truncated  bool
	kernelSeen map[string]bool
}

// ParseDpkgStatus reads /var/lib/dpkg/status (stanzas separated by blank lines) and keeps the
// versions of the packages in want. At most 16 MiB are read by the caller.
func ParseDpkgStatus(b []byte, want ...string) Dpkg {
	d := Dpkg{Installed: map[string]string{}, kernelSeen: map[string]bool{}}
	w := map[string]bool{}
	for _, x := range want {
		w[x] = true
	}
	var name, status, version string
	flush := func() {
		if name == "" {
			return
		}
		f := strings.Fields(status) // want flag status
		if len(f) == 3 {
			if f[0] == "hold" && len(d.Held) < 500 {
				d.Held = append(d.Held, name)
			}
			if f[2] != "not-installed" && f[2] != "config-files" {
				if f[2] == "installed" {
					d.Packages++
					if w[name] {
						d.Installed[name] = version
					}
					if k, ok := strings.CutPrefix(name, "linux-image-"); ok && k != "" && k[0] >= '0' && k[0] <= '9' && !d.kernelSeen[k] {
						d.kernelSeen[k] = true
						d.Kernels = append(d.Kernels, k)
					}
				} else if len(d.Broken) < 500 {
					d.Broken = append(d.Broken, name+" ("+f[2]+")")
				}
			}
		}
		name, status, version = "", "", ""
	}
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		l := sc.Text()
		if l == "" {
			flush()
			continue
		}
		switch {
		case strings.HasPrefix(l, "Package: "):
			name = strings.TrimSpace(l[9:])
			if !pkgName(name) {
				name = ""
			}
		case strings.HasPrefix(l, "Status: "):
			status = l[8:]
		case strings.HasPrefix(l, "Version: "):
			version = strings.TrimSpace(l[9:])
		}
	}
	if sc.Err() != nil {
		d.Truncated = true
	}
	flush()
	sort.Strings(d.Held)
	SortVersions(d.Kernels)
	return d
}

// ParseDpkgAudit reads `dpkg --audit`: the indented package lines under each explanation.
func ParseDpkgAudit(b []byte) []string {
	var res []string
	for _, l := range lines(b, 5000) {
		if !strings.HasPrefix(l, " ") {
			continue
		}
		f := strings.Fields(l)
		if len(f) > 0 && pkgName(f[0]) && len(res) < 200 {
			res = append(res, f[0])
		}
	}
	return res
}

// UUConfig is the effective configuration of unattended-upgrades (`apt-config dump`).
type UUConfig struct {
	Periodic, ListsDaily, Enabled bool // APT::Periodic::Enable (default on), Update-Package-Lists, Unattended-Upgrade
	SecurityOrigin, OtherOrigins  bool // an allowed origin is a -security pocket; one is not
	AutoReboot                    bool // Unattended-Upgrade::Automatic-Reboot
}

// ParseAptConfig reads `apt-config dump` (lines `Key "value";`).
func ParseAptConfig(b []byte) UUConfig {
	c := UUConfig{Periodic: true}
	for _, l := range lines(b, 20000) {
		k, v, ok := strings.Cut(l, " ")
		if !ok {
			continue
		}
		v = strings.TrimSuffix(strings.TrimSpace(v), ";")
		v = strings.Trim(v, `"`)
		on := v != "" && v != "0" && !strings.EqualFold(v, "false") && !strings.EqualFold(v, "no")
		switch k {
		case "APT::Periodic::Enable":
			c.Periodic = on
		case "APT::Periodic::Update-Package-Lists":
			c.ListsDaily = on
		case "APT::Periodic::Unattended-Upgrade":
			c.Enabled = on
		case "Unattended-Upgrade::Automatic-Reboot":
			c.AutoReboot = on
		case "Unattended-Upgrade::Allowed-Origins::", "Unattended-Upgrade::Origins-Pattern::":
			switch {
			case strings.Contains(v, "-security"):
				c.SecurityOrigin = true
			case strings.HasSuffix(v, "${distro_codename}") || strings.Contains(v, "a=${distro_codename},") || v == "":
				// the release pocket itself: changes only with a new release
			default:
				c.OtherOrigins = true
			}
		}
	}
	return c
}

// ParseNftChains reads `nft list chains`: whether a base chain on the input hook drops by
// default, and whether there is any input base chain at all.
func ParseNftChains(b []byte) (inputDrop, inputChain bool) {
	for _, l := range lines(b, 20000) {
		if !strings.Contains(l, "hook input") {
			continue
		}
		inputChain = true
		if strings.Contains(l, "policy drop") {
			inputDrop = true
		}
	}
	return
}

// UfwRule is one rule of /etc/ufw/user.rules (its "### tuple ###" comment lines).
type UfwRule struct {
	Action, Proto string // allow, deny, reject, limit; tcp, udp, any
	Port          string // "22", "80,443", "60000:61000", "any"
	In            bool
}

// ParseUfwRules reads ufw's user.rules or user6.rules:
//
//	### tuple ### allow tcp 22 0.0.0.0/0 any 0.0.0.0/0 in
//	### tuple ### limit tcp 22 0.0.0.0/0 any 0.0.0.0/0 in
func ParseUfwRules(b []byte) []UfwRule {
	var res []UfwRule
	for _, l := range lines(b, 20000) {
		rest, ok := strings.CutPrefix(l, "### tuple ### ")
		if !ok {
			continue
		}
		f := strings.Fields(rest)
		if len(f) < 7 {
			continue
		}
		r := UfwRule{Action: f[0], Proto: f[1], Port: f[2], In: f[len(f)-1] == "in" || strings.HasPrefix(f[len(f)-1], "in_")}
		if strings.HasPrefix(f[len(f)-1], "in") {
			r.In = true
		}
		res = append(res, r)
	}
	return res
}

// covers: the rule's port spec ("22", "80,443", "60000:61000", "any") includes port.
func (r UfwRule) covers(proto string, port int) bool {
	if r.Proto != "any" && r.Proto != proto {
		return false
	}
	if r.Port == "any" {
		return true
	}
	for _, p := range strings.Split(r.Port, ",") {
		lo, hi, rng := strings.Cut(p, ":")
		a, ok1 := decimal.Parse(lo, 5)
		if !ok1 {
			continue
		}
		b := a
		if rng {
			if x, ok := decimal.Parse(hi, 5); ok {
				b = x
			}
		}
		if int64(port) >= a && int64(port) <= b {
			return true
		}
	}
	return false
}

// JournalEntry is one line of `journalctl -o json --output-fields=...`.
type JournalEntry struct {
	At        int64 // seconds
	Transport string
	Ident     string
	Message   string
}

// ParseJournal reads `journalctl -o json` lines. A MESSAGE that is not text (journald sends
// bytes as an array of numbers) is skipped; so is anything that is not an object.
func ParseJournal(b []byte, max int) []JournalEntry {
	var res []JournalEntry
	for _, l := range lines(b, max) {
		if !strings.HasPrefix(l, "{") {
			continue
		}
		var m map[string]json.RawMessage
		if json.Unmarshal([]byte(l), &m) != nil {
			continue
		}
		var e JournalEntry
		var ts, msg string
		if json.Unmarshal(m["__REALTIME_TIMESTAMP"], &ts) != nil || json.Unmarshal(m["MESSAGE"], &msg) != nil {
			continue
		}
		us, ok := decimal.Parse(ts, 18)
		if !ok {
			continue
		}
		e.At, e.Message = us/1e6, msg
		json.Unmarshal(m["_TRANSPORT"], &e.Transport)
		json.Unmarshal(m["SYSLOG_IDENTIFIER"], &e.Ident)
		res = append(res, e)
	}
	return res
}

// KernelEvent classifies a kernel log message: "ioerr" (a disk or file system reports an I/O
// error or remounts read-only), "oom" (the OOM killer killed a process), or "".
func KernelEvent(msg string) string {
	m := msg
	switch {
	case strings.Contains(m, "Out of memory: Killed process"), strings.Contains(m, "Memory cgroup out of memory: Killed process"):
		return "oom"
	case strings.Contains(m, "I/O error"), strings.Contains(m, "critical medium error"),
		strings.Contains(m, "EXT4-fs error"), strings.Contains(m, "EXT4-fs warning") && strings.Contains(m, "I/O"),
		strings.Contains(m, "Remounting filesystem read-only"), strings.Contains(m, "XFS") && strings.Contains(m, "Corruption"),
		strings.Contains(m, "metadata I/O error"), strings.Contains(m, "BTRFS error"),
		strings.Contains(m, "nvme") && strings.Contains(m, "I/O") && strings.Contains(m, "timeout"):
		return "ioerr"
	}
	return ""
}

// SSHFailure: an sshd message about a failed login attempt (a wrong password, an unknown user,
// too many tries). Accepted keys and closed connections are not counted.
func SSHFailure(msg string) bool {
	return strings.HasPrefix(msg, "Failed password for") || strings.HasPrefix(msg, "Invalid user ") ||
		strings.HasPrefix(msg, "Failed keyboard-interactive") || strings.Contains(msg, "maximum authentication attempts exceeded") ||
		strings.HasPrefix(msg, "pam_unix(sshd:auth): authentication failure")
}

// SortVersions sorts kernel versions (6.8.0-49-generic < 6.8.0-51-generic < 6.11.0-9-generic)
// by comparing their runs of digits as numbers.
func SortVersions(v []string) {
	sort.SliceStable(v, func(i, j int) bool { return versionLess(v[i], v[j]) })
}

func versionLess(a, b string) bool {
	for a != "" && b != "" {
		da, db := digitsPrefix(a), digitsPrefix(b)
		switch {
		case da != "" && db != "":
			na, _ := strconv.ParseUint(strings.TrimLeft(da, "0")+"0", 10, 64)
			nb, _ := strconv.ParseUint(strings.TrimLeft(db, "0")+"0", 10, 64)
			if na != nb {
				return na < nb
			}
			a, b = a[len(da):], b[len(db):]
		case da != "" || db != "":
			return da != "" // digits sort after other characters... a "-rc" part sorts before
		default:
			if a[0] != b[0] {
				return a[0] < b[0]
			}
			a, b = a[1:], b[1:]
		}
	}
	return len(a) < len(b)
}

func digitsPrefix(s string) string {
	i := 0
	for i < len(s) && i < 18 && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	return s[:i]
}

// ParseFailedUnits reads `systemctl list-units --state=failed --plain --no-legend --full`:
// "unit load active sub description" per line.
func ParseFailedUnits(b []byte) []string {
	var res []string
	for _, l := range lines(b, 2000) {
		f := strings.Fields(l)
		if len(f) == 0 || f[0] == "●" || f[0] == "*" {
			if len(f) > 1 {
				f = f[1:]
			} else {
				continue
			}
		}
		if unitName(f[0]) && len(res) < 100 {
			res = append(res, f[0])
		}
	}
	return res
}

// unitName: a systemd unit name (systemd's own rule: [A-Za-z0-9:_.\@-], with a type suffix).
func unitName(s string) bool {
	if len(s) < 3 || len(s) > 256 || !strings.Contains(s, ".") {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte(":_.\\@-", c) >= 0) {
			return false
		}
	}
	return true
}
