package errscan

import "testing"

// Hours keeps the hours of the window (the hour holding its start included, as Window counts),
// drops older ones and malformed pairs, and keeps the order of the file.
func TestHours(t *testing.T) {
	data := "aaaaaaaa\t5\t1\t2\tr\tline\tl\tfp\tt\t3600:1,7200:2,10800:3\n" +
		"bbbbbbbb\t1\t1\t2\tr\tline\tl\tfp\tt\t3600:x,y:1,10800:0,14400:4\n" +
		"cccccccc\t1\t1\t2\tr\tline\tl\tfp\tt\n"
	got := Hours([]byte(data), 7300)
	want := map[string]string{"aaaaaaaa": "7200:2,10800:3", "bbbbbbbb": "14400:4", "cccccccc": ""}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: %q, want %q", k, got[k], v)
		}
	}
	if len(got) != len(want) {
		t.Errorf("%d groups, want %d: %q", len(got), len(want), got)
	}
}
