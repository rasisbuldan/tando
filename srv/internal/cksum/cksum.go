// Package cksum is POSIX cksum: what `cksum < file | cut -d' ' -f1` prints. tando-watch's show
// prints it for its own binary and tando-status's info for tando-agent; the client compares it
// with the checksum of the program it would install.
//
// A leaf: standard library only.
package cksum

import (
	"io"
	"os"
)

// table is the CRC table of the polynomial 0x04C11DB7, most significant bit first.
func table() *[256]uint32 {
	var tab [256]uint32
	for i := range tab {
		c := uint32(i) << 24
		for range 8 {
			if c&0x80000000 != 0 {
				c = c<<1 ^ 0x04C11DB7
			} else {
				c <<= 1
			}
		}
		tab[i] = c
	}
	return &tab
}

// Sum is the POSIX cksum of r's bytes: CRC-32 with polynomial 0x04C11DB7, most significant bit
// first, over the data and then its length (least significant byte first, as many bytes as it
// needs), inverted.
func Sum(r io.Reader) (uint32, error) {
	tab := table()
	var crc uint32
	var n uint64
	buf := make([]byte, 64<<10)
	for {
		k, err := r.Read(buf)
		for _, b := range buf[:k] {
			crc = crc<<8 ^ tab[byte(crc>>24)^b]
		}
		n += uint64(k)
		if err == io.EOF {
			break
		}
		if err != nil {
			return 0, err
		}
	}
	for ; n != 0; n >>= 8 {
		crc = crc<<8 ^ tab[byte(crc>>24)^byte(n)]
	}
	return ^crc, nil
}

// File is Sum of the file at path.
func File(path string) (uint32, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	return Sum(f)
}
