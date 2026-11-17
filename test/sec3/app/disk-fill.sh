#!/bin/bash
# sec3: run inside an app (as its user). Fills the file system of the app's data directory and keeps
# it full for $1 seconds (grabs any space that frees up, such as the agent's .reserve files).
end=$((SECONDS + ${1:-120})); d=${TANDO_DATA_DIR:-$HOME}/.fill; mkdir -p "$d"; i=0
while ((SECONDS < end)); do
  i=$((i + 1)); dd if=/dev/urandom of="$d/f$i" bs=1M count=64 2>/dev/null || { dd if=/dev/urandom of="$d/s$i" bs=4k count=256 2>/dev/null; sleep 0.2; }
done
