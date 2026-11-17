package offsite

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// The encrypted object format (docs/BACKUP.md, "Encryption"): a streaming AEAD from the
// standard library, AES-256-GCM over fixed-size chunks (the STREAM construction of Hoang,
// Reyhanitabar, Rogaway and Vizár, as Tink's and age's streaming encryption use it).
//
//	header   magic "TANDOBK1" (8) | alg 1 (1) | chunk shift (1) | 0 0 (2) | key id (8) |
//	         salt (32) | nonce prefix (7) | context length (2, big endian) | context (<= 512)
//	chunks   AES-256-GCM(subkey, nonce, chunk, aad = the whole header): every chunk holds
//	         exactly 2^shift bytes of plaintext but the last, which holds 0 .. 2^shift-1
//	subkey   HKDF-SHA256(the recovery key, salt, "tando offsite v1 chunk key"): a fresh key per
//	         object, so nonces never repeat across objects whatever the randomness of the prefix
//	nonce    prefix (7) | chunk counter (4, big endian) | last flag (1: 0x01 on the last chunk)
//
// A chunk moved, dropped, repeated or changed fails its tag (the counter is in the nonce); a cut
// at a chunk boundary is missing the chunk with the last flag; bytes after the last chunk are
// refused; the header (key id, context: the object's name) is authenticated by every chunk, so an
// object copied under another name (another app's backup) is refused as well.

const (
	cryptMagic    = "TANDOBK1"
	algAESGCM     = 1
	defaultShift  = 20 // 1 MiB chunks
	minShift      = 12
	maxShift      = 24
	saltLen       = 32
	prefixLen     = 7
	keyIDLen      = 8
	maxContext    = 512
	fixedHdrLen   = 8 + 1 + 1 + 2 + keyIDLen + saltLen + prefixLen + 2
	tagLen        = 16
	hkdfInfo      = "tando offsite v1 chunk key"
	maxChunkIndex = 1<<32 - 1
)

// ErrDecrypt is every failure to open an object: wrong key, damage, truncation, reordering.
var ErrDecrypt = errors.New("the object does not decrypt: damaged, truncated, or not this backup")

func headerLen(ctxLen int) int { return fixedHdrLen + ctxLen }

// cipherSize is the encrypted size of n plaintext bytes (the upload's size is known before it starts)
func cipherSize(n int64, shift uint, ctxLen int) int64 {
	c := int64(1) << shift
	full := n / c
	return int64(headerLen(ctxLen)) + full*(c+tagLen) + (n - full*c) + tagLen
}

func subkey(master, salt []byte) (cipher.AEAD, error) {
	k, err := hkdf.Key(sha256.New, master, salt, hkdfInfo, 32)
	if err != nil {
		return nil, err
	}
	b, err := aes.NewCipher(k)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(b)
}

// sealer encrypts a stream: Write the plaintext, Close to write the last chunk.
type sealer struct {
	w      io.Writer
	aead   cipher.AEAD
	hdr    []byte
	prefix []byte
	buf    []byte // one chunk of plaintext
	n      int
	ctr    uint64
	out    []byte
	closed bool
}

// newSealer writes the header to w. rnd supplies the salt and the nonce prefix.
func newSealer(w io.Writer, k Key, context string, shift uint, rnd io.Reader) (*sealer, error) {
	if len(context) > maxContext || shift < minShift || shift > maxShift {
		return nil, errors.New("bad encryption parameters")
	}
	rb := make([]byte, saltLen+prefixLen)
	if _, err := io.ReadFull(rnd, rb); err != nil {
		return nil, fmt.Errorf("random: %w", err)
	}
	salt, prefix := rb[:saltLen], rb[saltLen:]
	hdr := make([]byte, 0, headerLen(len(context)))
	hdr = append(hdr, cryptMagic...)
	hdr = append(hdr, algAESGCM, byte(shift), 0, 0)
	id := k.ID()
	hdr = append(hdr, id[:]...)
	hdr = append(hdr, salt...)
	hdr = append(hdr, prefix...)
	hdr = binary.BigEndian.AppendUint16(hdr, uint16(len(context)))
	hdr = append(hdr, context...)
	aead, err := subkey(k.Secret[:], salt)
	if err != nil {
		return nil, err
	}
	if _, err := w.Write(hdr); err != nil {
		return nil, err
	}
	c := 1 << shift
	return &sealer{w: w, aead: aead, hdr: hdr, prefix: append([]byte(nil), prefix...), buf: make([]byte, c), out: make([]byte, 0, c+tagLen)}, nil
}

func chunkNonce(prefix []byte, ctr uint64, last bool) []byte {
	n := make([]byte, 12)
	copy(n, prefix)
	binary.BigEndian.PutUint32(n[7:11], uint32(ctr))
	if last {
		n[11] = 1
	}
	return n
}

func (s *sealer) Write(p []byte) (int, error) {
	if s.closed {
		return 0, errors.New("write after close")
	}
	total := 0
	for len(p) > 0 {
		// a full chunk is sealed only when more follows: the last chunk must be the short one
		if s.n == len(s.buf) {
			if err := s.flush(false); err != nil {
				return total, err
			}
		}
		k := copy(s.buf[s.n:], p)
		s.n += k
		p = p[k:]
		total += k
	}
	return total, nil
}

func (s *sealer) flush(last bool) error {
	if s.ctr > maxChunkIndex {
		return errors.New("object too large to encrypt")
	}
	if !last && s.n < len(s.buf) {
		return nil
	}
	data := s.buf[:s.n]
	if last && s.n == len(s.buf) {
		// a full buffer at the end: it is a middle chunk, and an empty last chunk follows
		s.out = s.aead.Seal(s.out[:0], chunkNonce(s.prefix, s.ctr, false), data, s.hdr)
		if _, err := s.w.Write(s.out); err != nil {
			return err
		}
		s.ctr++
		data = s.buf[:0]
	}
	s.out = s.aead.Seal(s.out[:0], chunkNonce(s.prefix, s.ctr, last), data, s.hdr)
	if _, err := s.w.Write(s.out); err != nil {
		return err
	}
	s.ctr++
	s.n = 0
	return nil
}

// Close writes the last chunk (it does not close the underlying writer).
func (s *sealer) Close() error {
	if s.closed {
		return nil
	}
	s.closed = true
	return s.flush(true)
}

// header is a parsed object header.
type header struct {
	raw     []byte
	shift   uint
	keyID   [keyIDLen]byte
	salt    []byte
	prefix  []byte
	context string
}

func readHeader(r io.Reader) (header, error) {
	fixed := make([]byte, fixedHdrLen)
	if _, err := io.ReadFull(r, fixed); err != nil {
		return header{}, fmt.Errorf("%w (no complete header)", ErrDecrypt)
	}
	if string(fixed[:8]) != cryptMagic {
		return header{}, errors.New("not a tando offsite backup (wrong magic)")
	}
	if fixed[8] != algAESGCM || fixed[10] != 0 || fixed[11] != 0 {
		return header{}, errors.New("an offsite backup format this tando does not know (newer tando?)")
	}
	h := header{shift: uint(fixed[9])}
	if h.shift < minShift || h.shift > maxShift {
		return header{}, fmt.Errorf("%w (bad chunk size)", ErrDecrypt)
	}
	copy(h.keyID[:], fixed[12:20])
	h.salt = fixed[20 : 20+saltLen]
	h.prefix = fixed[20+saltLen : 20+saltLen+prefixLen]
	cl := int(binary.BigEndian.Uint16(fixed[fixedHdrLen-2:]))
	if cl > maxContext {
		return header{}, fmt.Errorf("%w (bad header)", ErrDecrypt)
	}
	ctx := make([]byte, cl)
	if _, err := io.ReadFull(r, ctx); err != nil {
		return header{}, fmt.Errorf("%w (no complete header)", ErrDecrypt)
	}
	h.context = string(ctx)
	h.raw = append(fixed, ctx...)
	return h, nil
}

// opener decrypts a stream; Read returns plaintext only from chunks that authenticated, and an
// error (never io.EOF) when the stream ends anywhere but after the last chunk.
type opener struct {
	r    *bufio.Reader
	aead cipher.AEAD
	h    header
	ctr  uint64
	in   []byte
	pt   []byte // decrypted, not yet returned
	done bool
	err  error
}

// newOpener reads the header; keys are tried by id. wantContext, when not empty, must equal the
// header's (the object's name).
func newOpener(r io.Reader, keys []Key, wantContext string) (*opener, error) {
	br := bufio.NewReaderSize(r, 64<<10)
	h, err := readHeader(br)
	if err != nil {
		return nil, err
	}
	if wantContext != "" && h.context != wantContext {
		return nil, fmt.Errorf("the object is %q, not %q: refused (copied or renamed in the bucket?)", cleanContext(h.context), wantContext)
	}
	var k *Key
	for i := range keys {
		if keys[i].ID() == h.keyID {
			k = &keys[i]
			break
		}
	}
	if k == nil {
		return nil, &NoKeyError{ID: h.keyID}
	}
	aead, err := subkey(k.Secret[:], h.salt)
	if err != nil {
		return nil, err
	}
	c := 1 << h.shift
	return &opener{r: br, aead: aead, h: h, in: make([]byte, c+tagLen), pt: make([]byte, 0, c)}, nil
}

// NoKeyError: the object was encrypted with a key this server does not hold.
type NoKeyError struct{ ID [keyIDLen]byte }

func (e *NoKeyError) Error() string {
	return fmt.Sprintf("encrypted with recovery key %x, which this server does not have: tando backup offsite key --import", e.ID[:])
}

func cleanContext(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c < 0x20 || c >= 0x7f {
			b[i] = '?'
		}
	}
	return string(b)
}

func (o *opener) Read(p []byte) (int, error) {
	for len(o.pt) == 0 {
		if o.err != nil {
			return 0, o.err
		}
		if o.done {
			return 0, io.EOF
		}
		o.err = o.next()
	}
	n := copy(p, o.pt)
	o.pt = o.pt[n:]
	return n, nil
}

func (o *opener) next() error {
	if o.ctr > maxChunkIndex {
		return ErrDecrypt
	}
	n, err := io.ReadFull(o.r, o.in)
	switch {
	case err == nil:
		// a full chunk is never the last one
		pt, oerr := o.aead.Open(o.pt[:0], chunkNonce(o.h.prefix, o.ctr, false), o.in, o.h.raw)
		if oerr != nil {
			return ErrDecrypt
		}
		o.pt = pt
		o.ctr++
		return nil
	case errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, io.EOF):
		if n < tagLen {
			return fmt.Errorf("%w (truncated)", ErrDecrypt)
		}
		pt, oerr := o.aead.Open(o.pt[:0], chunkNonce(o.h.prefix, o.ctr, true), o.in[:n], o.h.raw)
		if oerr != nil {
			return ErrDecrypt
		}
		o.pt = pt
		o.ctr++
		o.done = true
		return nil
	}
	return err
}

// plainSize: the plaintext size of an encrypted object of n bytes (-1: impossible size)
func plainSize(n int64, shift uint, ctxLen int) int64 {
	c := int64(1) << shift
	body := n - int64(headerLen(ctxLen))
	if body < tagLen {
		return -1
	}
	full := (body - tagLen) / (c + tagLen)
	rest := body - full*(c+tagLen) - tagLen
	if rest < 0 || rest >= c {
		return -1
	}
	return full*c + rest
}
