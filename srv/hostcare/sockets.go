package hostcare

import (
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Listener is a socket that listens on an address other hosts can reach, with its process.
type Listener struct {
	Proto string
	Addr  string // "0.0.0.0", "::", "203.0.113.7"
	Port  int
	UID   int
	Pid   int
	Comm  string // the process name (any user can set its own: cleaned, never trusted)
	Unit  string // the systemd unit of the process (from its cgroup)
	Class string // expected, guarded, allowed, blocked, exposed
	Why   string
}

// Key is "tcp/5432", as allow_ports names a port.
func (l Listener) Key() string { return l.Proto + "/" + strconv.Itoa(l.Port) }

// outside: an address another host can reach (not loopback; link-local counts as reachable on
// the local link, but a server's link-local listeners are DHCP and router discovery).
func outside(a netip.Addr) bool { return !a.IsLoopback() && !a.IsLinkLocalUnicast() }

// listeners reads the four /proc/net tables and keeps the sockets bound to an address that is
// not loopback, one per (proto, address, port): a server listening on 0.0.0.0 and :: is two.
func (h *Host) listeners() []Listener {
	var socks []Socket
	for _, t := range []struct{ file, proto string }{{"tcp", "tcp"}, {"tcp6", "tcp"}, {"udp", "udp"}, {"udp6", "udp"}} {
		socks = append(socks, ParseProcNet(readFile(filepath.Join(h.Env.Proc, "net", t.file), 8<<20), t.proto)...)
	}
	seen := map[string]bool{}
	var res []Listener
	want := map[uint64]int{}
	for _, s := range socks {
		if !outside(s.Addr) {
			continue
		}
		k := s.Proto + " " + s.Addr.String() + " " + strconv.Itoa(s.Port)
		if seen[k] {
			continue
		}
		seen[k] = true
		want[s.Inode] = len(res)
		res = append(res, Listener{Proto: s.Proto, Addr: s.Addr.String(), Port: s.Port, UID: s.UID, Pid: -1})
		if len(res) >= 500 {
			break
		}
	}
	h.owners(res, want)
	sort.Slice(res, func(i, j int) bool {
		if res[i].Port != res[j].Port {
			return res[i].Port < res[j].Port
		}
		if res[i].Proto != res[j].Proto {
			return res[i].Proto < res[j].Proto
		}
		return res[i].Addr < res[j].Addr
	})
	return res
}

// owners finds the process of each socket inode: /proc/<pid>/fd/* links read "socket:[ino]".
// It stops once every inode is found; at most 5000 processes and 200,000 descriptors are read.
func (h *Host) owners(ls []Listener, want map[uint64]int) {
	if len(want) == 0 {
		return
	}
	ents, err := os.ReadDir(h.Env.Proc)
	if err != nil {
		return
	}
	left, nfd := len(want), 0
	for i, e := range ents {
		if left == 0 || i > 5000 || nfd > 200000 {
			break
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		fdDir := filepath.Join(h.Env.Proc, e.Name(), "fd")
		fds, err := os.ReadDir(fdDir)
		if err != nil {
			continue
		}
		for _, fd := range fds {
			nfd++
			t, err := os.Readlink(filepath.Join(fdDir, fd.Name()))
			if err != nil || !strings.HasPrefix(t, "socket:[") {
				continue
			}
			ino, err := strconv.ParseUint(strings.TrimSuffix(t[8:], "]"), 10, 64)
			if err != nil {
				continue
			}
			j, ok := want[ino]
			if !ok || ls[j].Pid >= 0 {
				continue
			}
			ls[j].Pid = pid
			ls[j].Comm = clean(strings.TrimSpace(string(readFile(filepath.Join(h.Env.Proc, e.Name(), "comm"), 64))), 32)
			ls[j].Unit = unitOfCgroup(readFile(filepath.Join(h.Env.Proc, e.Name(), "cgroup"), 4096))
			left--
		}
	}
}

// unitOfCgroup: the unit of a process from /proc/<pid>/cgroup ("0::/system.slice/caddy.service"):
// the last path element that is a .service or .scope (a container's own path is ignored).
func unitOfCgroup(b []byte) string {
	for _, l := range lines(b, 50) {
		_, p, ok := strings.Cut(l, "::")
		if !ok {
			continue
		}
		el := strings.Split(p, "/")
		for i := len(el) - 1; i >= 0; i-- {
			if (strings.HasSuffix(el[i], ".service") || strings.HasSuffix(el[i], ".scope")) && unitName(el[i]) {
				return el[i]
			}
		}
	}
	return ""
}

// classify decides for each listener whether it is expected (sshd on its ports, Caddy on 80
// and 443, DHCP), guarded (a tando app: tando's nftables rules drop its answers to other hosts),
// allowed (allow_ports), blocked (ufw is active, drops by default and has no rule for it), or
// exposed (anything else: a database or an app port open to the world).
func classify(ls []Listener, ssh SSHD, fw Firewall, guardedUIDs map[int]bool, allowed map[string]bool) {
	sshPorts := map[int]bool{}
	for _, p := range ssh.Ports {
		sshPorts[p] = true
	}
	if len(sshPorts) == 0 {
		sshPorts[22] = true
	}
	for i := range ls {
		l := &ls[i]
		unit, comm := l.Unit, l.Comm
		isSSH := unit == "ssh.service" || unit == "sshd.service" || unit == "ssh.socket" || comm == "sshd" || strings.HasPrefix(unit, "sshd@")
		switch {
		case isSSH && l.Proto == "tcp" && sshPorts[l.Port]:
			l.Class, l.Why = "expected", "ssh"
		case unit == "init.scope" && comm == "systemd" && l.Proto == "tcp" && sshPorts[l.Port]:
			l.Class, l.Why = "expected", "ssh (ssh.socket)" // socket activation: systemd holds the port
		case unit == "caddy.service" && (l.Port == 80 || l.Port == 443) && (l.Proto == "tcp" || l.Port == 443):
			l.Class, l.Why = "expected", "Caddy"
		case l.Proto == "udp" && (l.Port == 68 || l.Port == 546) &&
			(unit == "systemd-networkd.service" || strings.HasPrefix(comm, "dhc") || comm == "systemd-network"):
			l.Class, l.Why = "expected", "DHCP client"
		case allowed[l.Key()]:
			l.Class, l.Why = "allowed", "allow_ports"
		case strings.HasPrefix(unit, "tando-") && guardedUIDs[l.UID]:
			l.Class, l.Why = "guarded", "a tando app: its answers to other hosts are dropped (firewall.nft)"
		default:
			l.Class, l.Why = "exposed", ""
		}
		if l.Class != "exposed" {
			continue
		}
		switch b := fw.Blocks(l.Proto, l.Port); b {
		case "yes":
			l.Class, l.Why = "blocked", "ufw drops it (no allow rule for "+l.Key()+")"
		case "unknown":
			l.Why = "a firewall drops incoming traffic by default, but whether it lets " + l.Key() + " through could not be determined"
		}
	}
}
