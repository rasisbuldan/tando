package offsite

import (
	"bytes"
	"crypto/rand"
	"errors"
	"io"
	mrand "math/rand/v2"
	"runtime"
	"strings"
	"testing"
	"time"
)

func testKey(t testing.TB) Key {
	k, err := NewKey(rand.Reader, 1)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func seal(t testing.TB, k Key, ctx string, shift uint, pt []byte) []byte {
	var b bytes.Buffer
	s, err := newSealer(&b, k, ctx, shift, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	// odd write sizes: chunk boundaries fall anywhere in a write
	for p := pt; len(p) > 0; {
		n := min(len(p), 1+mrand.IntN(5000))
		if _, err := s.Write(p[:n]); err != nil {
			t.Fatal(err)
		}
		p = p[n:]
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func open(keys []Key, ctx string, ct []byte) ([]byte, error) {
	o, err := newOpener(bytes.NewReader(ct), keys, ctx)
	if err != nil {
		return nil, err
	}
	return io.ReadAll(o)
}

func TestCryptRoundTrip(t *testing.T) {
	k := testKey(t)
	const shift = 12
	c := 1 << shift
	for _, n := range []int{0, 1, c - 1, c, c + 1, 3 * c, 3*c + 17, 10000} {
		pt := make([]byte, n)
		rand.Read(pt)
		ct := seal(t, k, "h/a/x.rbk", shift, pt)
		if int64(len(ct)) != cipherSize(int64(n), shift, len("h/a/x.rbk")) {
			t.Errorf("n=%d: size %d, cipherSize %d", n, len(ct), cipherSize(int64(n), shift, 9))
		}
		if plainSize(int64(len(ct)), shift, 9) != int64(n) {
			t.Errorf("n=%d: plainSize", n)
		}
		got, err := open([]Key{testKey(t), k}, "h/a/x.rbk", ct)
		if err != nil || !bytes.Equal(got, pt) {
			t.Fatalf("n=%d: round trip: %v", n, err)
		}
	}
}

// Every change fails closed: a flipped bit anywhere, a cut at any length, chunks swapped,
// dropped or repeated, bytes appended, another context, another key.
func TestCryptTamper(t *testing.T) {
	k := testKey(t)
	const shift = 12
	pt := bytes.Repeat([]byte("secret-marker "), 1000) // 14000 bytes: 4 chunks
	ct := seal(t, k, "h/a/x.rbk", shift, pt)
	keys := []Key{k}
	for i := 0; i < len(ct); i++ {
		for _, bit := range []byte{1, 0x80} {
			m := append([]byte(nil), ct...)
			m[i] ^= bit
			if got, err := open(keys, "h/a/x.rbk", m); err == nil {
				t.Fatalf("bit flip at %d accepted (%d bytes)", i, len(got))
			}
		}
	}
	for n := 0; n < len(ct); n++ {
		if _, err := open(keys, "h/a/x.rbk", ct[:n]); err == nil {
			t.Fatalf("cut at %d accepted", n)
		}
	}
	if _, err := open(keys, "h/a/x.rbk", append(append([]byte(nil), ct...), 0)); err == nil {
		t.Fatal("appended byte accepted")
	}
	h := headerLen(len("h/a/x.rbk"))
	cs := 1<<shift + tagLen
	c0, c1 := ct[h:h+cs], ct[h+cs:h+2*cs]
	swapped := append(append(append(append([]byte(nil), ct[:h]...), c1...), c0...), ct[h+2*cs:]...)
	if _, err := open(keys, "h/a/x.rbk", swapped); err == nil {
		t.Fatal("swapped chunks accepted")
	}
	dropped := append(append([]byte(nil), ct[:h]...), ct[h+cs:]...)
	if _, err := open(keys, "h/a/x.rbk", dropped); err == nil {
		t.Fatal("dropped chunk accepted")
	}
	repeated := append(append(append([]byte(nil), ct[:h+cs]...), c0...), ct[h+cs:]...)
	if _, err := open(keys, "h/a/x.rbk", repeated); err == nil {
		t.Fatal("repeated chunk accepted")
	}
	// the last full chunk as the end: a cut exactly at a chunk boundary
	if _, err := open(keys, "h/a/x.rbk", ct[:h+3*cs]); err == nil {
		t.Fatal("cut at a chunk boundary accepted")
	}
	if _, err := open(keys, "h/b/x.rbk", ct); err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("another object's name: %v", err)
	}
	var nk *NoKeyError
	if _, err := open([]Key{testKey(t)}, "", ct); !errors.As(err, &nk) {
		t.Fatalf("another key: %v", err)
	}
}

type genReader struct{ n, off int64 }

func (g *genReader) Read(p []byte) (int, error) {
	if g.off >= g.n {
		return 0, io.EOF
	}
	k := int(min(int64(len(p)), g.n-g.off))
	for i := 0; i < k; i++ {
		p[i] = byte((g.off + int64(i)) * 7)
	}
	g.off += int64(k)
	return k, nil
}

type checkWriter struct{ off int64 }

func (c *checkWriter) Write(p []byte) (int, error) {
	for i := range p {
		if p[i] != byte((c.off+int64(i))*7) {
			return 0, errors.New("mismatch")
		}
	}
	c.off += int64(len(p))
	return len(p), nil
}

// A stream of 1.5 GB through encryption and decryption in a pipe: the heap stays small.
func TestCryptLargeBoundedMemory(t *testing.T) {
	if testing.Short() {
		t.Skip("short")
	}
	const n = 1536 << 20
	k := testKey(t)
	pr, pw := io.Pipe()
	go func() {
		s, err := newSealer(pw, k, "h/a/big.rbk", defaultShift, rand.Reader)
		if err == nil {
			_, err = io.Copy(s, &genReader{n: n})
		}
		if err == nil {
			err = s.Close()
		}
		pw.CloseWithError(err)
	}()
	stopWatch := watchHeap()
	o, err := newOpener(pr, []Key{k}, "h/a/big.rbk")
	if err != nil {
		t.Fatal(err)
	}
	cw := &checkWriter{}
	if _, err := io.Copy(cw, o); err != nil || cw.off != n {
		t.Fatalf("copy: %v, %d bytes", err, cw.off)
	}
	peak := stopWatch()
	if peak > 64<<20 {
		t.Fatalf("heap peaked at %d MB", peak>>20)
	}
	t.Logf("1.5 GB, heap peak %d MB", peak>>20)
}

func TestKeyText(t *testing.T) {
	k := testKey(t)
	s := k.Text()
	if !strings.HasPrefix(s, "tando-key-") || len(s) != len("tando-key-")+14*4+13 {
		t.Fatalf("text form %q", s)
	}
	for _, v := range []string{s, strings.ToUpper(s), strings.ReplaceAll(strings.TrimPrefix(s, "tando-key-"), "-", " "), "  " + s + "\n"} {
		k2, err := ParseKey(v)
		if err != nil || k2.Secret != k.Secret {
			t.Fatalf("ParseKey(%q): %v", v, err)
		}
	}
	// one wrong character is caught by the checksum
	b := []byte(s)
	i := len(b) - 5
	if b[i] == 'a' {
		b[i] = 'b'
	} else {
		b[i] = 'a'
	}
	if _, err := ParseKey(string(b)); err == nil {
		t.Fatal("typo accepted")
	}
	for _, bad := range []string{"", "tando-key-", "tando-key-abcd", s + "a", strings.Replace(s, "a", "1", 1)} {
		if _, err := ParseKey(bad); err == nil && bad != s {
			t.Errorf("ParseKey(%q) accepted", bad)
		}
	}
	ks := []Key{k, testKey(t)}
	ks[1].Current, ks[0].Current, ks[0].Saved = false, true, 5
	got, err := parseKeys(formatKeys(ks))
	if err != nil || len(got) != 2 || got[0].Secret != k.Secret || !got[0].Current || got[0].Saved != 5 {
		t.Fatalf("key file round trip: %v %+v", err, got)
	}
	if _, err := parseKeys([]byte("x\ty\n")); err == nil {
		t.Fatal("bad key file accepted")
	}
}

// watchHeap samples the heap in use every 20 ms until the returned function is called, which
// returns the peak
func watchHeap() func() uint64 {
	stop, res := make(chan bool), make(chan uint64)
	go func() {
		var ms runtime.MemStats
		var peak uint64
		for {
			select {
			case <-stop:
				res <- peak
				return
			case <-time.After(20 * time.Millisecond):
				runtime.ReadMemStats(&ms)
				peak = max(peak, ms.HeapInuse)
			}
		}
	}()
	return func() uint64 { close(stop); return <-res }
}
