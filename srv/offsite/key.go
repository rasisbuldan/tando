package offsite

import (
	"bytes"
	"crypto/sha256"
	"encoding/base32"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/decimal"
)

// The recovery key: 256 random bits made on the server, kept in /opt/tando/offsite.key (root,
// 600) and shown to the admin once. Without it the offsite backups cannot be read.
//
// Its text form is easy to copy and to write down: "tando-key-" and 14 groups of 4 characters
// (RFC 4648 base32, lower case) of the key and a 3-byte checksum, so a typo is caught before
// anything is tried with it:
//
//	tando-key-abcd-efgh-ijkl-mnop-qrst-uvwx-yz23-4567-abcd-efgh-ijkl-mnop-qrst-uvwx
//
// The key id (in every object's header, and shown next to the key) is the first 8 bytes of
// SHA-256("tando-offsite-key-id\x00" || key): it names a key without revealing it.

const keyPrefix = "tando-key-"

// Key is one recovery key.
type Key struct {
	Secret  [32]byte
	Created int64
	Current bool  // new uploads use it (exactly one key is current)
	Saved   int64 // when the admin confirmed it is stored safely (0: not yet)
}

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

func keyHash(tag string, k []byte) [32]byte {
	return sha256.Sum256(append([]byte(tag+"\x00"), k...))
}

// ID names the key.
func (k Key) ID() [keyIDLen]byte {
	h := keyHash("tando-offsite-key-id", k.Secret[:])
	var id [keyIDLen]byte
	copy(id[:], h[:keyIDLen])
	return id
}

// IDHex is the id as shown.
func (k Key) IDHex() string { id := k.ID(); return hex.EncodeToString(id[:]) }

// Text is the key's text form.
func (k Key) Text() string {
	c := keyHash("tando-offsite-key-check", k.Secret[:])
	s := strings.ToLower(b32.EncodeToString(append(k.Secret[:], c[:3]...)))
	var b strings.Builder
	b.WriteString(keyPrefix)
	for i := 0; i < len(s); i += 4 {
		if i > 0 {
			b.WriteByte('-')
		}
		b.WriteString(s[i:min(i+4, len(s))])
	}
	return b.String()
}

// ParseKey reads a key's text form: case, spaces and dashes do not matter, the prefix may be
// left out; the checksum must match.
func ParseKey(s string) (Key, error) {
	s = strings.ToLower(strings.TrimSpace(s))
	s = strings.TrimPrefix(s, keyPrefix)
	s = strings.Map(func(r rune) rune {
		if r == '-' || r == ' ' || r == '\t' {
			return -1
		}
		return r
	}, s)
	if len(s) != 56 {
		return Key{}, errors.New("a recovery key is tando-key- and 56 letters and digits (14 groups of 4)")
	}
	b, err := b32.DecodeString(strings.ToUpper(s))
	if err != nil || len(b) != 35 {
		return Key{}, errors.New("not a recovery key: only the letters a-z and the digits 2-7 appear in one")
	}
	var k Key
	copy(k.Secret[:], b[:32])
	c := keyHash("tando-offsite-key-check", k.Secret[:])
	if !bytes.Equal(c[:3], b[32:]) {
		return Key{}, errors.New("the recovery key's checksum does not match: a character is wrong (compare it with the copy you stored)")
	}
	return k, nil
}

// NewKey makes a key from rnd (crypto/rand).
func NewKey(rnd io.Reader, now int64) (Key, error) {
	var k Key
	if _, err := io.ReadFull(rnd, k.Secret[:]); err != nil {
		return Key{}, fmt.Errorf("random: %w", err)
	}
	k.Created, k.Current = now, true
	return k, nil
}

// The key file: a comment, then one line per key, tab-separated:
//
//	<id hex> <text form> <created epoch> current|old <saved epoch, 0 = not confirmed>
const keyFileHead = "# tando offsite recovery keys (root only). Without them the offsite backups cannot be read.\n"

func formatKeys(ks []Key) []byte {
	var b bytes.Buffer
	b.WriteString(keyFileHead)
	for _, k := range ks {
		role := "old"
		if k.Current {
			role = "current"
		}
		fmt.Fprintf(&b, "%s\t%s\t%d\t%s\t%d\n", k.IDHex(), k.Text(), k.Created, role, k.Saved)
	}
	return b.Bytes()
}

func parseKeys(b []byte) ([]Key, error) {
	var ks []Key
	cur := 0
	for i, l := range strings.Split(string(b), "\n") {
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		f := strings.Split(l, "\t")
		if len(f) != 5 {
			return nil, fmt.Errorf("key file line %d: bad format", i+1)
		}
		k, err := ParseKey(f[1])
		if err != nil {
			return nil, fmt.Errorf("key file line %d: %v", i+1, err)
		}
		if k.IDHex() != f[0] || !decimal.IsDigits(f[2]) || !decimal.IsDigits(f[4]) || (f[3] != "current" && f[3] != "old") {
			return nil, fmt.Errorf("key file line %d: bad format", i+1)
		}
		k.Created, _ = strconv.ParseInt(f[2], 10, 64)
		k.Saved, _ = strconv.ParseInt(f[4], 10, 64)
		k.Current = f[3] == "current"
		if k.Current {
			cur++
		}
		ks = append(ks, k)
	}
	if len(ks) > 0 && cur != 1 {
		return nil, errors.New("key file: not exactly one current key")
	}
	return ks, nil
}

// loadKeys reads the key file (missing: no keys). Root's, 600, a regular file, never a link.
func loadKeys(path string, uid int) ([]Key, error) {
	b, err := readRootFile(path, 1<<20, uid)
	if isNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return parseKeys(b)
}

func saveKeys(path string, ks []Key) error {
	return atomicfile.Write(path, formatKeys(ks), atomicfile.Mode(0o600))
}

func currentKey(ks []Key) (Key, bool) {
	for _, k := range ks {
		if k.Current {
			return k, true
		}
	}
	return Key{}, false
}
