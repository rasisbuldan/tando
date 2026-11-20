package pgwire

import (
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strconv"
	"strings"
)

// SCRAM-SHA-256 (RFC 5802, RFC 7677) without channel binding ("n,,": no TLS on loopback).
type scram struct {
	user, pw, nonce string
	clientFirstBare string
	authMsg         string
	salted          []byte
	done            bool
}

func newScram(user, pw, nonce string) *scram {
	if nonce == "" {
		b := make([]byte, 18)
		rand.Read(b)
		nonce = base64.RawStdEncoding.EncodeToString(b)
	}
	return &scram{user: user, pw: pw, nonce: nonce}
}

func (s *scram) first() string {
	s.clientFirstBare = "n=" + s.user + ",r=" + s.nonce
	return "n,," + s.clientFirstBare
}

// maxIterations: a server asking for more is refused (the CPU of a 1 vCPU host; PostgreSQL's
// default is 4096)
const maxIterations = 1 << 20

func (s *scram) final(serverFirst []byte) ([]byte, error) {
	sf := string(serverFirst)
	var r, salt string
	iter := 0
	for _, a := range strings.Split(sf, ",") {
		k, v, ok := strings.Cut(a, "=")
		if !ok {
			return nil, errors.New("SCRAM: bad server-first message")
		}
		switch k {
		case "r":
			r = v
		case "s":
			salt = v
		case "i":
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 || n > maxIterations {
				return nil, errors.New("SCRAM: bad iteration count")
			}
			iter = n
		case "m":
			return nil, errors.New("SCRAM: unsupported extension")
		}
	}
	if !strings.HasPrefix(r, s.nonce) || len(r) == len(s.nonce) || iter == 0 {
		return nil, errors.New("SCRAM: the server's nonce does not extend ours")
	}
	sb, err := base64.StdEncoding.DecodeString(salt)
	if err != nil || len(sb) == 0 {
		return nil, errors.New("SCRAM: bad salt")
	}
	s.salted, err = pbkdf2.Key(sha256.New, s.pw, sb, iter, 32)
	if err != nil {
		return nil, err
	}
	without := "c=biws,r=" + r
	s.authMsg = s.clientFirstBare + "," + sf + "," + without
	ck := mac(s.salted, "Client Key")
	stored := sha256.Sum256(ck)
	sig := mac(stored[:], s.authMsg)
	for i := range ck {
		ck[i] ^= sig[i]
	}
	return []byte(without + ",p=" + base64.StdEncoding.EncodeToString(ck)), nil
}

func (s *scram) verify(serverFinal []byte) bool {
	v, ok := strings.CutPrefix(string(serverFinal), "v=")
	if !ok || s.salted == nil {
		return false
	}
	got, err := base64.StdEncoding.DecodeString(v)
	return err == nil && hmac.Equal(got, mac(mac(s.salted, "Server Key"), s.authMsg))
}

func mac(key []byte, msg string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(msg))
	return h.Sum(nil)
}
