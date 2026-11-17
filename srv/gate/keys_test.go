package gate

import (
	"strings"
	"testing"

	"tando/srv/internal/bashread"
)

// a throwaway key made with ssh-keygen -t ed25519, and the fingerprint ssh-keygen -l printed
const (
	tPub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKRO/QSS+GTRv49Pb0jaMuX8rDtMJ9Wk/9WZTW3oWJT0"
	tFP  = "SHA256:WJrQE69CmQx/hLbOG00k3MNdhY1nQkgpvVFUdpMCKZA"
)

func TestParsePublicKey(t *testing.T) {
	for _, l := range []string{tPub, tPub + " tando-ci-alpha", tPub + " a@b.c:d-e_f", tPub + " "} {
		pub, fp, err := ParsePublicKey(l)
		if err != nil || pub != tPub || fp != tFP {
			t.Errorf("%q: %q %q %v", l, pub, fp, err)
		}
	}
	// the first character after "I" carries the low bits of the length byte: anything above P
	// makes it a key of another length, which ssh-keygen refused
	bad := tPub[:len("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI")] + "z" + tPub[len("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI")+1:]
	for l, msg := range map[string]string{
		"": "expected one ssh-ed25519 public key",
		"ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQDDINO+lGBsF86HBYVx9ymW": "expected one",
		tPub + "\n":                          "expected one",
		tPub + " " + tPub:                    "expected one",
		"restrict " + tPub:                   "expected one",
		tPub + ` x"`:                         "expected one",
		tPub + " " + strings.Repeat("a", 81): "expected one",
		"ssh-ed25519  " + tPub[12:]:          "expected one",
		tPub[:len(tPub)-1]:                   "expected one",
		tPub + "A":                           "expected one",
		bad:                                  "not a valid ed25519 key",
	} {
		if _, _, err := ParsePublicKey(l); err == nil || !strings.HasPrefix(err.Error(), msg) {
			t.Errorf("%q: %v, want %q", l, err, msg)
		}
	}
}

func TestTabRead(t *testing.T) {
	tests := []struct {
		in   string
		n    int
		want []string
	}{
		{"a\tb\tc\td e\tf", 5, []string{"a", "b", "c", "d e", "f"}},
		{"a\t\tb", 3, []string{"a", "b", ""}},
		{"\ta\tb\t", 2, []string{"a", "b"}},
		{"a\tb\tc\td\te\tf", 5, []string{"a", "b", "c", "d", "e\tf"}},
		{"", 3, []string{"", "", ""}},
		{"only", 3, []string{"only", "", ""}},
	}
	for _, tt := range tests {
		if got := bashread.Fields(tt.in, tt.n); strings.Join(got, "|") != strings.Join(tt.want, "|") {
			t.Errorf("bashread.Fields(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestAuthorizedKeys(t *testing.T) {
	keys := keyLine("0123456789ab", tFP, 1700000000, tPub, "admin") +
		"bad-id\t" + tFP + "\t1\t" + tPub + "\tx\n" + // not a key id
		"0123456789ac\t" + tFP + "\t1\tssh-ed25519 AAAA,command=\"x\"\tx\n" + // not a key: skipped
		"0123456789ad\t" + tFP + "\t1\t" + tPub + "\tlast" // no newline: bash's read loop skipped it
	got := string(AuthorizedKeys([]byte(keys), tGate, "alpha"))
	want := `restrict,command="/opt/tando/bin/tando-gate key 0123456789ab" ` + tPub + " tando-ci-alpha-0123456789ab\n"
	if got != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
}

func TestKeyList(t *testing.T) {
	k := []byte(keyLine("0123456789ab", tFP, 1, tPub, "a") + keyLine("0123456789ac", "SHA256:x", 2, tPub, "b"))
	if !keyActive(k, "0123456789ab") || keyActive(k, "0123456789a") || keyActive(k, "SHA256:x") {
		t.Error("keyActive")
	}
	if !hasFingerprint(k, tFP) || hasFingerprint(k, "SHA256:") {
		t.Error("hasFingerprint")
	}
	if ids := keyIDs(k); strings.Join(ids, ",") != "0123456789ab,0123456789ac" {
		t.Errorf("keyIDs %v", ids)
	}
	kept, ids, n := revokeSel(k, tFP)
	if n != 1 || len(ids) != 1 || ids[0] != "0123456789ab" || string(kept) != keyLine("0123456789ac", "SHA256:x", 2, tPub, "b") {
		t.Errorf("revoke by fingerprint: %q %v %d", kept, ids, n)
	}
	if _, _, n := revokeSel(k, "0123456789ac"); n != 1 {
		t.Error("revoke by id")
	}
	if _, _, n := revokeSel(k, "nothing"); n != 0 {
		t.Error("revoke nothing")
	}
	if countNonEmpty([]byte("a\n\nb")) != 2 {
		t.Error("countNonEmpty")
	}
	for s, ok := range map[string]bool{"0123456789ab": true, tFP: true, "all": false, "0123456789aB": false, "SHA256:" + strings.Repeat("a", 42): false} {
		if revokeSelRe.MatchString(s) != ok {
			t.Errorf("revoke selector %q", s)
		}
	}
}
