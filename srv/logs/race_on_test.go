//go:build race

package logs

// raceOn: the race detector allocates on its own, so allocation counts are not checked under it.
const raceOn = true
