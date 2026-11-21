package dash

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Session model (review B5): the opening link carries a one-time code (60 s, single use); /open
// trades it for an HttpOnly, SameSite=Strict cookie that lasts 30 days, so a tab left open
// survives reloads and a restart of tando-dash (the sessions are kept on disk as SHA-256
// hashes, 0600). The page itself never sees a secret.

const cookieName = "tando_dash"
const maxSessions = 64
const maxCodes = 16

type sessions struct {
	mu    sync.Mutex
	file  string
	now   func() time.Time
	codes map[string]time.Time // code -> expiry
	m     map[string]time.Time // sha256(token) hex -> expiry
}

func newSessions(file string, now func() time.Time) *sessions {
	s := &sessions{file: file, now: now, codes: map[string]time.Time{}, m: map[string]time.Time{}}
	if b, err := os.ReadFile(file); err == nil {
		var m map[string]time.Time
		if json.Unmarshal(b, &m) == nil {
			for k, v := range m {
				if len(k) == 64 && v.After(now()) {
					s.m[k] = v
				}
			}
		}
	}
	return s
}

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func hashHex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func (s *sessions) newCode(ttl time.Duration) string {
	c := randHex(16)
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for k, exp := range s.codes {
		if !exp.After(now) {
			delete(s.codes, k)
		}
	}
	for len(s.codes) >= maxCodes {
		oldest(s.codes)
	}
	s.codes[c] = now.Add(ttl)
	return c
}

// useCode: true once per code, within its TTL
func (s *sessions) useCode(c string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, exp := range s.codes {
		if subtle.ConstantTimeCompare([]byte(k), []byte(c)) == 1 {
			delete(s.codes, k)
			return exp.After(s.now())
		}
	}
	return false
}

func (s *sessions) create(ttl time.Duration) string {
	tok := randHex(32)
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for k, exp := range s.m {
		if !exp.After(now) {
			delete(s.m, k)
		}
	}
	for len(s.m) >= maxSessions {
		oldest(s.m)
	}
	s.m[hashHex(tok)] = now.Add(ttl)
	s.saveLocked()
	return tok
}

func (s *sessions) valid(r *http.Request) bool {
	c, err := r.Cookie(cookieName)
	if err != nil || len(c.Value) != 64 {
		return false
	}
	h := hashHex(c.Value)
	s.mu.Lock()
	defer s.mu.Unlock()
	exp, ok := s.m[h]
	return ok && exp.After(s.now())
}

func (s *sessions) saveLocked() {
	b, _ := json.Marshal(s.m)
	_ = writeFileAtomic(s.file, b, 0o600)
}

func oldest(m map[string]time.Time) {
	var ok string
	var ot time.Time
	for k, t := range m {
		if ok == "" || t.Before(ot) {
			ok, ot = k, t
		}
	}
	delete(m, ok)
}

// open: GET /open?code=...: the code for the cookie, then to / (the code leaves the address bar)
func (s *Server) open(w http.ResponseWriter, r *http.Request) {
	code := r.URL.Query().Get("code")
	if code == "" || !s.sess.useCode(code) {
		sessionEnded(w)
		return
	}
	tok := s.sess.create(s.cfg.SessionTTL)
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: tok, Path: "/", MaxAge: int(s.cfg.SessionTTL / time.Second),
		HttpOnly: true, SameSite: http.SameSiteStrictMode})
	s.lastUse.Store(s.cfg.Now().UnixNano())
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Location", "/")
	w.WriteHeader(http.StatusSeeOther)
}

// sessionEnded: the one full-page state of the design guideline (§7), plain HTML, no script
// or style (the CSP allows none inline)
func sessionEnded(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusUnauthorized)
	_, _ = w.Write([]byte(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>tando</title><link rel="icon" href="/favicon.svg"></head>
<body><main><h1>Session ended.</h1><p>Open the dashboard again with <code>tando-dash</code>.</p></main></body></html>
`))
}

// writeFileAtomic: a temp file in the same directory (mode), then rename
func writeFileAtomic(path string, b []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".tmp-"+filepath.Base(path)+"-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	err = f.Chmod(mode)
	if err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}
