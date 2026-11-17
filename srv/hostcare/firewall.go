package hostcare

import (
	"context"
	"strings"
)

// Firewall is what is known of the server's packet filter for incoming traffic.
type Firewall struct {
	Ufw      bool      // ufw is enabled (ufw.conf) and its unit is active
	UfwDeny  bool      // its default for incoming traffic is deny or reject
	Rules    []UfwRule // its user rules (IPv4 and IPv6)
	NftDrop  bool      // an nftables base chain on the input hook drops by default
	NftChain bool      // there is such a chain at all
	NftKnown bool      // nft could be asked
}

// Blocks: "yes" when the firewall drops incoming traffic to the port, "no" when it lets it
// through (or there is no firewall), "unknown" when a firewall drops by default but its rules
// are not ufw's (hand-written nftables: not parsed).
func (f Firewall) Blocks(proto string, port int) string {
	if f.Ufw {
		allow, deny := false, false
		for _, r := range f.Rules {
			if !r.In || !r.covers(proto, port) {
				continue
			}
			switch r.Action {
			case "allow", "limit":
				allow = true
			case "deny", "reject":
				deny = true
			}
		}
		switch {
		case allow:
			return "no"
		case deny || f.UfwDeny:
			return "yes"
		}
		return "no"
	}
	if f.NftDrop {
		return "unknown"
	}
	return "no"
}

// Describe is the firewall in a few words.
func (f Firewall) Describe() string {
	switch {
	case f.Ufw && f.UfwDeny:
		return "ufw active, incoming denied by default"
	case f.Ufw:
		return "ufw active, but incoming is allowed by default"
	case f.NftDrop:
		return "nftables drops incoming by default (rules not read by tando)"
	case f.NftChain:
		return "nftables has an input chain that accepts by default"
	}
	return "none: every listening port is reachable"
}

// Limits: ufw rate-limits the ssh port (`ufw limit 22/tcp`).
func (f Firewall) Limits(port int) bool {
	for _, r := range f.Rules {
		if r.In && r.Action == "limit" && r.covers("tcp", port) {
			return true
		}
	}
	return false
}

// firewall reads ufw's own files (no python: `ufw status` costs 150 ms); without ufw it asks
// reads /etc/nftables.conf (no program is started).
func (h *Host) firewall(_ context.Context, units map[string]string) Firewall {
	var f Firewall
	conf := ParseOSRelease(readFile(h.p("/etc/ufw/ufw.conf"), 64<<10))
	if strings.EqualFold(conf["ENABLED"], "yes") && units["ufw.service"] == "active" {
		f.Ufw = true
		def := ParseOSRelease(readFile(h.p("/etc/default/ufw"), 64<<10))
		p := strings.ToUpper(def["DEFAULT_INPUT_POLICY"])
		f.UfwDeny = p == "DROP" || p == "REJECT"
		f.Rules = append(ParseUfwRules(readFile(h.p("/etc/ufw/user.rules"), 4<<20)), ParseUfwRules(readFile(h.p("/etc/ufw/user6.rules"), 4<<20))...)
		return f
	}
	// no nft call: the boot-time ruleset file says what policy the input chain has (a ruleset
	// loaded by hand later is not seen: "unknown" is then said, never guessed)
	if b := readFile(h.p("/etc/nftables.conf"), 4<<20); b != nil {
		f.NftKnown = true
		f.NftDrop, f.NftChain = ParseNftChains(b)
	}
	return f
}
