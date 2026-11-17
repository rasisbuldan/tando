package offsite

import (
	"sort"
	"strconv"
	"time"
)

// Offsite retention, per app, over the objects this server wrote (its host id's directory; never
// another server's, never a sweep of the bucket). By default the local policy: the newest 7
// daily backups, the newest of each of the 4 ISO weeks before them, the newest 5 of each other
// kind, every final; keep_* settings keep more (e.g. keep_daily=30 keep_monthly=12).
//
// Clocks: the policy counts backups by their ids, so a clock set wrong deletes no more than a
// count allows; and whatever the ids say, the keep_min objects the storage received last (its
// own Last-Modified, not this server's clock) are kept. A run whose clock is more than 5 minutes
// off the storage's deletes nothing (sync.go).

// prune returns the ids to delete, oldest first.
func prune(bs []remoteBackup, k Keep) []string {
	sorted := append([]remoteBackup(nil), bs...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].id > sorted[j].id })
	keep := map[string]bool{}
	ndaily := 0
	weeks, months := map[string]bool{}, map[string]bool{}
	count := map[string]int{}
	for _, b := range sorted {
		kind := backupKind(b.id)
		switch kind {
		case "final":
			keep[b.id] = true
		case "daily":
			ndaily++
			if ndaily <= k.Daily {
				keep[b.id] = true
				continue
			}
			t := time.Unix(backupTime(b.id), 0).UTC()
			y, wk := t.ISOWeek()
			w := strconv.Itoa(y) + "-" + strconv.Itoa(wk)
			if !weeks[w] && len(weeks) < k.Weekly {
				weeks[w] = true
				keep[b.id] = true
			}
			m := t.Format("2006-01")
			if !months[m] && len(months) < k.Monthly {
				months[m] = true
				keep[b.id] = true
			}
		default:
			count[kind]++
			if count[kind] <= k.Other {
				keep[b.id] = true
			}
		}
	}
	// the newest by the storage's clock, whatever the ids say
	byMod := append([]remoteBackup(nil), bs...)
	sort.SliceStable(byMod, func(i, j int) bool { return byMod[i].modified.After(byMod[j].modified) })
	for i := 0; i < len(byMod) && i < k.Min; i++ {
		keep[byMod[i].id] = true
	}
	var del []string
	for i := len(sorted) - 1; i >= 0; i-- {
		if !keep[sorted[i].id] {
			del = append(del, sorted[i].id)
		}
	}
	return del
}
