package reqlog

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"hash/maphash"
	"io"
	"math"
)

// The request index: for each request log file a "segment" of fixed-size records, one per line
// that parses, in the file's order, and a dictionary of the path keys they use. A record holds
// what req-summary, the scan and req-errors need from a line, already parsed: folding records
// with Summary.AddRecord gives the same bytes as Summary.Add over the lines (same values, same
// order of every floating-point sum), for a fraction of the cost. Package logs keeps the files.

// RecordSize is the bytes of one record.
const RecordSize = 32

// NotCounted is the path id of a line that is not a request (no status and no method).
const NotCounted = ^uint32(0)

// MaxKeyLen: a path key longer than this is not put in a dictionary (only a method over a few
// hundred bytes makes one); its segment is then read from the log instead.
const MaxKeyLen = 512

// Record is one line of a request log, parsed.
type Record struct {
	Ts, Dur float64 // as the line has them
	Off     uint32  // where the line starts in the file (uncompressed)
	Path    uint32  // dictionary id of its path key, NotCounted
	Status  uint16
	Bin     uint16 // BinOf(Dur)
}

// Put writes r into b (RecordSize bytes, little endian).
func (r *Record) Put(b []byte) {
	_ = b[RecordSize-1]
	binary.LittleEndian.PutUint64(b[0:], math.Float64bits(r.Ts))
	binary.LittleEndian.PutUint64(b[8:], math.Float64bits(r.Dur))
	binary.LittleEndian.PutUint32(b[16:], r.Off)
	binary.LittleEndian.PutUint32(b[20:], r.Path)
	binary.LittleEndian.PutUint16(b[24:], r.Status)
	binary.LittleEndian.PutUint16(b[26:], r.Bin)
	binary.LittleEndian.PutUint32(b[28:], 0)
}

// Get reads r from b.
func (r *Record) Get(b []byte) {
	_ = b[RecordSize-1]
	r.Ts = math.Float64frombits(binary.LittleEndian.Uint64(b[0:]))
	r.Dur = math.Float64frombits(binary.LittleEndian.Uint64(b[8:]))
	r.Off = binary.LittleEndian.Uint32(b[16:])
	r.Path = binary.LittleEndian.Uint32(b[20:])
	r.Status = binary.LittleEndian.Uint16(b[24:])
	r.Bin = binary.LittleEndian.Uint16(b[26:])
}

// Indexable reports whether a parsed request fits a record: an integral status 0-65535 (Caddy
// writes 3 digits) and a line offset under 4 GiB. A line that does not makes its segment one that
// is read from the log.
func Indexable(r *Request, off int64) bool {
	return r.Status >= 0 && r.Status <= 65535 && r.Status == math.Trunc(r.Status) && off >= 0 && off <= math.MaxUint32
}

// Keys is a dictionary as its file holds it (each key: its length in 2 bytes, then its bytes),
// in 64 KiB chunks that a key never straddles (so it grows without copying), and where each key
// starts (chunk<<16 | offset): no string per key, 4 bytes of index each.
type Keys struct {
	chunks [][]byte
	offs   []uint32
	size   int // bytes of the file form
}

const keyChunk = 64 << 10

// LoadKeys reads a dictionary file of size bytes; ok is false when it is cut short or damaged.
func LoadKeys(r io.Reader, size int64) (Keys, bool) {
	var k Keys
	br := bufio.NewReaderSize(r, 32<<10)
	var hdr [2]byte
	key := make([]byte, MaxKeyLen) // (one buffer for all: an array in the loop would escape each time)
	var read int64
	for read < size {
		if _, err := io.ReadFull(br, hdr[:]); err != nil {
			return k, false
		}
		n := int(binary.LittleEndian.Uint16(hdr[:]))
		if n > MaxKeyLen {
			return k, false
		}
		if _, err := io.ReadFull(br, key[:n]); err != nil {
			return k, false
		}
		k.add(key[:n])
		read += int64(2 + n)
	}
	return k, read == size
}

// ParseKeys reads a dictionary file's bytes.
func ParseKeys(b []byte) (Keys, bool) { return LoadKeys(bytes.NewReader(b), int64(len(b))) }

// Len is the number of keys.
func (k *Keys) Len() int { return len(k.offs) }

// Key is key id's bytes.
func (k *Keys) Key(id uint32) []byte {
	loc := k.offs[id]
	c := k.chunks[loc>>16]
	o := loc & 0xffff
	n := uint32(binary.LittleEndian.Uint16(c[o:]))
	return c[o+2 : o+2+n : o+2+n]
}

// add appends a key in its file form; the new id is Len()-1.
func (k *Keys) add(key []byte) {
	need := 2 + len(key)
	last := len(k.chunks) - 1
	if last < 0 || len(k.chunks[last])+need > cap(k.chunks[last]) {
		// chunks of 1 KiB, doubling to 64 KiB: a dictionary of a few paths takes a few KiB
		size := 1 << 10
		if last >= 0 {
			size = min(2*cap(k.chunks[last]), keyChunk)
		}
		k.chunks = append(k.chunks, make([]byte, 0, size))
		last++
	}
	c := k.chunks[last]
	k.offs = append(k.offs, uint32(last)<<16|uint32(len(c)))
	c = binary.LittleEndian.AppendUint16(c, uint16(len(key)))
	k.chunks[last] = append(c, key...)
	k.size += need
}

// Dict assigns path keys their ids in order of first use (the writer's side): Keys and an
// open-addressing table of ids (4 bytes a slot, at most 3/4 full, built when first asked).
type Dict struct {
	Keys
	saved int      // keys already in the file
	table []uint32 // id+1, 0 empty
	seed  maphash.Seed
}

// NewDict continues a dictionary whose file holds k.
func NewDict(k Keys) *Dict { return &Dict{Keys: k, saved: k.Len()} }

// ID is key's id, a new one when it has none; ok is false when the keys would take more than
// maxBytes (a client spraying unique paths) or the key is longer than MaxKeyLen.
func (d *Dict) ID(key []byte, maxBytes int) (uint32, bool) {
	if d.table == nil {
		d.seed = maphash.MakeSeed()
		d.grow(max(64, len(d.offs)*4/3+1))
	}
	mask := uint64(len(d.table) - 1)
	h := maphash.Bytes(d.seed, key) & mask
	for ; d.table[h] != 0; h = (h + 1) & mask {
		if id := d.table[h] - 1; string(d.Key(id)) == string(key) {
			return id, true
		}
	}
	if d.size+2+len(key) > maxBytes || len(key) > MaxKeyLen || len(d.offs) >= int(NotCounted-2) {
		return 0, false
	}
	d.add(key)
	id := uint32(len(d.offs) - 1)
	d.table[h] = id + 1
	if 4*len(d.offs) > 3*len(d.table) { // a load of 3/4 at most
		d.grow(2 * len(d.table))
	}
	return id, true
}

func (d *Dict) grow(n int) {
	size := 64
	for size < n {
		size *= 2
	}
	d.table = make([]uint32, size)
	mask := uint64(size - 1)
	for id := range d.offs {
		h := maphash.Bytes(d.seed, d.Key(uint32(id))) & mask
		for d.table[h] != 0 {
			h = (h + 1) & mask
		}
		d.table[h] = uint32(id) + 1
	}
}

// Unsaved: the dictionary file's bytes not written yet; Saved marks them written.
func (d *Dict) Unsaved() []byte {
	var b []byte
	for id := d.saved; id < len(d.offs); id++ {
		k := d.Key(uint32(id))
		b = binary.LittleEndian.AppendUint16(b, uint16(len(k)))
		b = append(b, k...)
	}
	return b
}

// Mem is about what the dictionary holds in memory, in bytes.
func (d *Dict) Mem() int {
	n := 4*cap(d.offs) + 4*len(d.table) + 64
	for _, c := range d.chunks {
		n += cap(c)
	}
	return n
}

// Pending: keys not written yet.
func (d *Dict) Pending() bool { return d.saved < len(d.offs) }

// Saved marks Unsaved written.
func (d *Dict) Saved() { d.saved = len(d.offs) }

// SegView is a segment being folded into a Summary: its keys and, per id, the summary's path
// aggregate (-1: not looked up yet).
type SegView struct {
	Keys  Keys
	cache []int32
}

// AddRecord counts one record of segment v, exactly as Add counts its line.
func (s *Summary) AddRecord(r *Record, v *SegView) bool {
	if !s.inWindow(r.Ts, r.Path != NotCounted) {
		return true
	}
	if int(r.Path) >= v.Keys.Len() {
		return false
	}
	st := float64(r.Status)
	s.count(r.Ts, st, r.Dur, int(r.Bin))
	if v.cache == nil {
		v.cache = make([]int32, v.Keys.Len())
		for i := range v.cache {
			v.cache[i] = -1
		}
	}
	i := int(v.cache[r.Path])
	if i < 0 {
		k := v.Keys.Key(r.Path)
		var ok bool
		if i, ok = s.paths[string(k)]; !ok {
			i = s.newPath(k)
		}
		v.cache[r.Path] = int32(i)
	}
	s.addPath(i, st, r.Dur)
	return true
}
