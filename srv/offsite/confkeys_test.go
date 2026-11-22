package offsite

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// The disaster-recovery copy of an app's settings must carry every per-app tando.conf key the agent
// records (CONF_KEYS_A in server/tando-agent), or a restored app comes back without them. spa is
// the one key configure takes that the agent keeps outside CONF_KEYS_A.
func TestConfKeysMatchAgent(t *testing.T) {
	b, err := os.ReadFile("../../server/tando-agent")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)\nCONF_KEYS_A=\((.*?)\)\n`).FindSubmatch(b)
	if m == nil {
		t.Fatal("CONF_KEYS_A not found in server/tando-agent")
	}
	want := map[string]bool{"spa": true}
	for _, k := range strings.Fields(string(m[1])) {
		want[k] = true
	}
	var missing, extra []string
	for k := range want {
		if !confKeys[k] {
			missing = append(missing, k)
		}
	}
	for k := range confKeys {
		if !want[k] {
			extra = append(extra, k)
		}
	}
	sort.Strings(missing)
	sort.Strings(extra)
	if len(missing) > 0 || len(extra) > 0 {
		t.Errorf("confKeys differs from the agent's CONF_KEYS_A: missing %v, not in the agent %v", missing, extra)
	}
}
