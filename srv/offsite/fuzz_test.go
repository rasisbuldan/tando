package offsite

import (
	"bytes"
	"io"
	"testing"
)

// fixed key for the fuzz targets (a seed object is valid under it)
func fuzzKey() Key {
	var k Key
	for i := range k.Secret {
		k.Secret[i] = byte(i * 13)
	}
	return k
}

// FuzzOpen: whatever the bytes, decryption errs or returns plaintext that was really sealed;
// it never panics, never returns plaintext from a stream that did not end with its last chunk.
func FuzzOpen(f *testing.F) {
	k := fuzzKey()
	for _, n := range []int{0, 10, 4096, 9000} {
		var b bytes.Buffer
		s, _ := newSealer(&b, k, "h/a/x.rbk", 12, bytes.NewReader(make([]byte, 64)))
		s.Write(bytes.Repeat([]byte{7}, n))
		s.Close()
		f.Add(b.Bytes())
		f.Add(b.Bytes()[:b.Len()/2])
	}
	f.Add([]byte(cryptMagic))
	f.Fuzz(func(t *testing.T, ct []byte) {
		o, err := newOpener(bytes.NewReader(ct), []Key{k}, "h/a/x.rbk")
		if err != nil {
			return
		}
		pt, err := io.ReadAll(o)
		if err == nil && int64(len(pt)) != plainSize(int64(len(ct)), o.h.shift, len(o.h.context)) {
			t.Fatalf("accepted %d bytes from %d", len(pt), len(ct))
		}
	})
}

func FuzzParseList(f *testing.F) {
	f.Add([]byte(`<ListBucketResult><Contents><Key>p/a</Key><Size>3</Size><LastModified>2026-01-01T00:00:00Z</LastModified></Contents><CommonPrefixes><Prefix>p/x/</Prefix></CommonPrefixes><IsTruncated>true</IsTruncated><NextContinuationToken>t</NextContinuationToken></ListBucketResult>`))
	f.Add([]byte(`<Error><Code>AccessDenied</Code></Error>`))
	f.Fuzz(func(t *testing.T, b []byte) {
		p, err := parseList(b, "p/")
		if err != nil {
			return
		}
		for _, o := range p.Objects {
			if len(o.Key) < 2 || o.Key[:2] != "p/" || o.Size < 0 {
				t.Fatalf("accepted %+v", o)
			}
		}
	})
}

func FuzzReadBundle(f *testing.F) {
	var b bytes.Buffer
	writeBundle(&b, []entry{{name: "meta", data: []byte("kind=daily\n"), size: 11}, {name: "db.dump", data: []byte("x"), size: 1}})
	f.Add(b.Bytes())
	f.Add([]byte(bundleMagic + "F\x02..\x00\x00\x00\x00\x00\x00\x00\x01xE"))
	f.Fuzz(func(t *testing.T, in []byte) {
		readBundle(bytes.NewReader(in), 1<<20, func(name string, size int64, r io.Reader) error {
			if !bundleNames[name] {
				t.Fatalf("name %q passed", name)
			}
			_, err := io.Copy(io.Discard, r)
			return err
		})
	})
}

func FuzzParseKey(f *testing.F) {
	f.Add(fuzzKey().Text())
	f.Add("tando-key-")
	f.Fuzz(func(t *testing.T, s string) {
		k, err := ParseKey(s)
		if err == nil {
			if k2, err := ParseKey(k.Text()); err != nil || k2.Secret != k.Secret {
				t.Fatal("round trip")
			}
		}
		parseKeys([]byte(s))
	})
}
