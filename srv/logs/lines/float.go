package lines

import "strconv"

// parseFloat reads a decimal number already checked by numEnd. strconv rounds correctly, as
// glibc's strtod does, so values (and their printed forms) match awk's.
func parseFloat(b []byte) float64 {
	// a short number converts on the stack; strconv sees a string either way
	f, err := strconv.ParseFloat(string(b), 64)
	if err != nil {
		// out of range: ParseFloat returns ±Inf with the error, strtod the same
		return f
	}
	return f
}
