#!/bin/bash
# runs ON the server (copied to /root/sampler.sh): every second, one line per cgroup:
# epoch  cgroup  cpu_usec  anon+shmem_bytes  memory.current  tasks
# usage: sampler.sh <outfile> <stopfile> cgroup...   ("" = the whole container)
set -u
out=$1 stop=$2; shift 2
: > "$out"
while [ ! -e "$stop" ]; do
  t=$(date +%s.%N | cut -c1-14)
  for c in "$@"; do
    d=/sys/fs/cgroup/$c
    [ -d "$d" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "${c:-TOTAL}" \
      "$(sed -n 's/^usage_usec //p' "$d/cpu.stat")" \
      "$(awk '$1=="anon"||$1=="shmem"{s+=$2} END{print s+0}' "$d/memory.stat")" \
      "$(cat "$d/memory.current")" "$(wc -l < "$d/cgroup.procs")"
  done >> "$out"
  sleep 1
done
