package gate

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"regexp"
	"strings"

	"tando/srv/internal/bashread"
)

// The key list, CI/<app>/keys (root 600), one line per key:
//
//	<key id>\t<SHA256:fingerprint>\t<created, epoch>\t<ssh-ed25519 AAAA...>\t<who added it>
//
// and authorized_keys (root:tando-keys 640), rebuilt from it, one line per key:
//
//	restrict,command="<gate> key <key id>" ssh-ed25519 AAAA... tando-ci-<app>-<key id>

var (
	// one ssh-ed25519 public key line, as `tando ci setup` sends it (the comment is dropped)
	pubLineRe = regexp.MustCompile(`^(ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43})( [A-Za-z0-9_.@:-]{0,80})?$`)
	pubRe     = regexp.MustCompile(`^ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}$`)
	fpRe      = regexp.MustCompile(`^SHA256:[A-Za-z0-9+/]{43}$`)
)

// ParsePublicKey checks one public key line and returns the key ("ssh-ed25519 <base64>") and its
// fingerprint as ssh-keygen -l prints it. The blob must be exactly an ed25519 key: the string
// "ssh-ed25519" and a 32-byte key, each with its length (what ssh-keygen -l checked).
func ParsePublicKey(line string) (pub, fp string, err error) {
	m := pubLineRe.FindStringSubmatch(line)
	if m == nil {
		return "", "", die("expected one ssh-ed25519 public key")
	}
	pub = m[1]
	blob, derr := base64.StdEncoding.Strict().DecodeString(strings.TrimPrefix(pub, "ssh-ed25519 "))
	want := append([]byte{0, 0, 0, 11}, "ssh-ed25519"...)
	want = append(want, 0, 0, 0, 32)
	if derr != nil || len(blob) != len(want)+32 || !bytes.HasPrefix(blob, want) {
		return "", "", die("not a valid ed25519 key")
	}
	sum := sha256.Sum256(blob)
	fp = "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
	if !fpRe.MatchString(fp) {
		return "", "", die("not a valid ed25519 key")
	}
	return pub, fp, nil
}

// awkFields splits like awk -F'\t' (one tab, one separator).
func awkFields(l string) []string { return strings.Split(l, "\t") }

// keyLine is one line of the key list.
func keyLine(id, fp string, created int64, pub, who string) string {
	return fmt.Sprintf("%s\t%s\t%d\t%s\t%s\n", id, fp, created, pub, who)
}

// AuthorizedKeys renders authorized_keys from the key list: one line per key whose id and
// public key are well-formed (the shell checked the id only; a damaged list cannot inject key
// options or a second key into the file sshd reads).
func AuthorizedKeys(keys []byte, gate, app string) []byte {
	var b bytes.Buffer
	for _, l := range bashread.Lines(keys) {
		f := bashread.Fields(l, 5)
		id, pub := f[0], f[3]
		if !validKeyID(id) || !pubRe.MatchString(pub) {
			continue
		}
		fmt.Fprintf(&b, "restrict,command=\"%s key %s\" %s tando-ci-%s-%s\n", gate, id, pub, app, id)
	}
	return b.Bytes()
}

// keyActive: the key list has a line for id (grep -q "^<id>\t").
func keyActive(keys []byte, id string) bool {
	for _, l := range bashread.LinesAll(keys) {
		if strings.HasPrefix(l, id+"\t") {
			return true
		}
	}
	return false
}

// hasFingerprint: a key with this fingerprint is registered (grep -q "\t<fp>\t").
func hasFingerprint(keys []byte, fp string) bool {
	return bytes.Contains(keys, []byte("\t"+fp+"\t"))
}

// keyIDs are the first fields of the key list (cut -f1), lines with something in them.
func keyIDs(keys []byte) []string {
	var r []string
	for _, l := range bashread.LinesAll(keys) {
		if id := awkFields(l)[0]; id != "" {
			r = append(r, id)
		}
	}
	return r
}

// revokeSel selects key lines by id or fingerprint (awk -F'\t' '$1 == s || $2 == s'); it
// returns the kept list, the ids removed and how many lines matched.
func revokeSel(keys []byte, sel string) (kept []byte, ids []string, n int) {
	var b bytes.Buffer
	for _, l := range bashread.LinesAll(keys) {
		f := awkFields(l)
		if f[0] == sel || (len(f) > 1 && f[1] == sel) {
			n++
			if f[0] != "" {
				ids = append(ids, f[0])
			}
			continue
		}
		b.WriteString(l)
		b.WriteByte('\n')
	}
	return b.Bytes(), ids, n
}

// countNonEmpty is grep -c . (lines with at least one character).
func countNonEmpty(data []byte) int {
	n := 0
	for _, l := range bashread.LinesAll(data) {
		if l != "" {
			n++
		}
	}
	return n
}

var revokeSelRe = regexp.MustCompile(`^([0-9a-f]{12}|SHA256:[A-Za-z0-9+/]{43})$`)
