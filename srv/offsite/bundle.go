package offsite

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
)

// A bundle is the plaintext of an offsite object: a few named files one after the other, in a
// format whose size is known before it is written (the upload's part size depends on it).
//
//	"RBKB1\n"                                      magic (6 bytes)
//	'F' | name length (1) | name | size (8, big endian) | the bytes     per file
//	'E'                                            end
//
// Names come from a fixed list (bundleNames): a reader writes nothing else, anywhere.

const bundleMagic = "RBKB1\n"

// bundleNames: every name an entry may have, and where fetch puts it in a backup directory
var bundleNames = map[string]bool{
	"meta": true, "data.tar.gz": true, "db.dump": true, // the backup itself (as on the server)
	"config/app.conf": true, "config/env": true, // the app (to recreate it elsewhere)
	"inventory": true, "host.conf": true, // the server's inventory object
}

type entry struct {
	name string
	f    *os.File // a file (size bytes are read from it), or
	data []byte   // bytes in memory
	size int64
}

func bundleSize(es []entry) int64 {
	n := int64(len(bundleMagic)) + 1
	for _, e := range es {
		n += 1 + 1 + int64(len(e.name)) + 8 + e.size
	}
	return n
}

func writeBundle(w io.Writer, es []entry) error {
	if _, err := io.WriteString(w, bundleMagic); err != nil {
		return err
	}
	for _, e := range es {
		if !bundleNames[e.name] {
			return fmt.Errorf("internal: bundle name %q", e.name)
		}
		h := make([]byte, 0, 2+len(e.name)+8)
		h = append(h, 'F', byte(len(e.name)))
		h = append(h, e.name...)
		h = binary.BigEndian.AppendUint64(h, uint64(e.size))
		if _, err := w.Write(h); err != nil {
			return err
		}
		var src io.Reader
		if e.f != nil {
			src = e.f
		} else {
			src = &bytesReader{b: e.data}
		}
		n, err := io.CopyN(w, src, e.size)
		if err != nil {
			if n < e.size && (err == io.EOF || errors.Is(err, io.ErrUnexpectedEOF)) {
				return fmt.Errorf("%s shrank while it was read", e.name)
			}
			return err
		}
	}
	_, err := w.Write([]byte{'E'})
	return err
}

type bytesReader struct{ b []byte }

func (r *bytesReader) Read(p []byte) (int, error) {
	if len(r.b) == 0 {
		return 0, io.EOF
	}
	n := copy(p, r.b)
	r.b = r.b[n:]
	return n, nil
}

// readBundle calls fn for each entry with a reader of exactly its bytes (fn must read them all
// or return an error). maxSize bounds an entry.
func readBundle(r io.Reader, maxSize int64, fn func(name string, size int64, r io.Reader) error) error {
	m := make([]byte, len(bundleMagic))
	if _, err := io.ReadFull(r, m); err != nil || string(m) != bundleMagic {
		return errors.New("not a tando offsite bundle")
	}
	seen := map[string]bool{}
	for {
		var t [2]byte
		if _, err := io.ReadFull(r, t[:1]); err != nil {
			return errors.New("bundle: truncated")
		}
		if t[0] == 'E' {
			// the stream must end here: io.EOF from the decryption means its last chunk was seen
			var x [1]byte
			n, err := io.ReadFull(r, x[:])
			if n != 0 {
				return errors.New("bundle: bytes after the end")
			}
			if err != io.EOF {
				return fmt.Errorf("bundle: %w", err)
			}
			return nil
		}
		if t[0] != 'F' {
			return errors.New("bundle: bad entry")
		}
		if _, err := io.ReadFull(r, t[1:2]); err != nil {
			return errors.New("bundle: truncated")
		}
		nb := make([]byte, int(t[1])+8)
		if _, err := io.ReadFull(r, nb); err != nil {
			return errors.New("bundle: truncated")
		}
		name := string(nb[:t[1]])
		size := int64(binary.BigEndian.Uint64(nb[t[1]:]))
		if !bundleNames[name] || seen[name] || size < 0 || size > maxSize {
			return fmt.Errorf("bundle: unexpected entry %q", cleanContext(name))
		}
		seen[name] = true
		lr := &io.LimitedReader{R: r, N: size}
		if err := fn(name, size, lr); err != nil {
			return err
		}
		if lr.N != 0 {
			if _, err := io.Copy(io.Discard, lr); err != nil || lr.N != 0 {
				return errors.New("bundle: truncated")
			}
		}
	}
}
