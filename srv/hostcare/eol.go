package hostcare

import "time"

// eolTable: the end of standard support of each Ubuntu release (security updates for the main
// archive without Ubuntu Pro). From Canonical's release cycle page
// (https://ubuntu.com/about/release-cycle) and the end-of-life notices on the ubuntu-announce
// list. Where only a month is announced, its last day is used. MUST BE REFRESHED with every
// Ubuntu release (each April and October): a release that is not here is reported as "unknown",
// never guessed. Last checked: 2026-11 (tando 0.x).
var eolTable = map[string]string{
	"18.04": "2023-05-31", // bionic
	"20.04": "2025-05-29", // focal
	"22.04": "2027-06-30", // jammy (announced: June 2027)
	"23.10": "2024-07-11", // mantic
	"24.04": "2029-05-31", // noble (announced: May 2029)
	"24.10": "2025-07-10", // oracular
	"25.04": "2026-01-15", // plucky
	"25.10": "2026-07-09", // questing
	"26.04": "2031-05-31", // resolute (announced: May 2031)
}

// EOL is the end of standard support of an Ubuntu release (VERSION_ID), and whether it is known.
func EOL(id, version string) (time.Time, bool) {
	if id != "ubuntu" {
		return time.Time{}, false
	}
	d, ok := eolTable[version]
	if !ok {
		return time.Time{}, false
	}
	t, err := time.Parse("2006-01-02", d)
	if err != nil {
		return time.Time{}, false
	}
	return t.Add(24*time.Hour - time.Second), true // the end of that day (UTC)
}
