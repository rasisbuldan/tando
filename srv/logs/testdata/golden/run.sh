#!/bin/bash
# runs the shell version's awk programs (verbatim from server/legacy/tando-logs, the 3rd argument)
# on the corpora in $1 (gen.py), writing the golden outputs to $2. Run under mawk, LC_ALL=C, as
# the server does, in a tando-testvm container:
#   docker run --rm -v "$PWD:/w" -v "$REPO/server/legacy:/src:ro" --entrypoint /bin/bash \
#     tando-testvm:caddy-ubuntu /w/run.sh /w/in /w/gold /src/tando-logs
# The files are stored gzip'd (gzip -9 -n), the inputs as <name>.gz, the outputs as out-<name>.gz.
set -u
I=$1 O=$2 SRC=$3
export LC_ALL=C
for v in AWK_JOURNAL AWK_STATS AWK_REQLIB AWK_SUMMARY AWK_REQROWS AWK_ERRSCAN AWK_ERRMERGE AWK_REQSCAN; do
  eval "$(sed -n "/^read -r -d '' $v <<'AWK'/,/^AWK\$/p" "$SRC")"
done
T0=1794587950 NOW=$((1794587950 + 3600))
# error scan
SUMF=$O/errscan.sum awk "$AWK_ERRSCAN" < "$I/journal.short" > "$O/errscan.out"
RELS="$((T0 - 100)):20261115-013512,$((T0 + 2000)):20261116-090000-2"
for v in "base0 0 200" "base1 1 200" "max5 0 5"; do
  set -- $v
  rm -f "$O/merge.$1.groups"
  OUT=$O/merge.$1.groups REL=20261116-090000-2 RELS=$RELS NOW=$NOW BASE=$2 MAX=$3 \
    awk "$AWK_ERRMERGE" "$I/groups.tsv" "$O/errscan.out" > "$O/merge.$1.out"
  [ -f "$O/merge.$1.groups" ] || : > "$O/merge.$1.groups"
done
# the errors view (cmd_errors' awk, verbatim)
for v in "86400 20" "3600 5" "999999 999"; do
  set -- $v
  awk -F'\t' -v from=$(( NOW - $1 )) -v n="$2" '
    { if ($4 < from) next
      c = 0; k = split($10, P, ","); for (i = 1; i <= k; i++) { split(P[i], q, ":"); if (q[1] + 3600 > from) c += q[2] }
      if (c == 0) c = 1
      r[++m] = $4 "\t" $1 "\t" c "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $9 }
    END { for (i = 2; i <= m; i++) { x = r[i]; j = i - 1; while (j >= 1 && (r[j] + 0) < (x + 0)) { r[j + 1] = r[j]; j-- } r[j + 1] = x }
      for (i = 1; i <= m && i <= n; i++) { sub(/^[^\t]*\t/, "", r[i]); print "err\t" r[i] } }' "$O/merge.base0.groups" > "$O/window.$1.$2"
done
# request log
for v in "3600 60" "900 15" "125 2" "604800 60"; do
  set -- $v
  W=$1 NOW=$NOW NB=$2 awk "$AWK_REQLIB$AWK_SUMMARY" < "$I/access.log" > "$O/summary.$1"
done
tail -n 50 "$I/access.log" | FROM=0 MINST=0 N=50 FLUSH=0 awk "$AWK_REQLIB$AWK_REQROWS" > "$O/rows.tail50"
FROM=$((NOW - 3600)) MINST=500 N=40 FLUSH=0 awk "$AWK_REQLIB$AWK_REQROWS" < "$I/access.log" > "$O/rows.err500"
FROM=$((NOW - 7200)) MINST=400 N=9999 FLUSH=0 awk "$AWK_REQLIB$AWK_REQROWS" < "$I/access.log" > "$O/rows.err400"
CH=$(wc -c < "$I/access-chunk.log") awk "$AWK_REQLIB$AWK_REQSCAN" < "$I/access-chunk.log" > "$O/reqscan.out"
# journal queries
UNITS="tando-boom.service=app systemd-journald@tando-boom.service=journald tando-boom-job-backup.service=job:backup"
q() { # name FMT LVL PAT PMODE CUR TZOFF TZS RANGES
  UNITS=$UNITS FMT=$2 LVL=$3 PAT=$4 PMODE=$5 CUR=$6 TZOFF=$7 TZS=$8 RANGES=$9 N=0 CURF= FLUSH=0 OLDF= \
    awk "$AWK_JOURNAL" < "$I/journal.json" > "$O/journal.$1"
}
q text text "" "" "" 0 0 +00:00 ""
q json json "" "" "" 1 25200 +07:00 ""
q lvl3 text 3 "" "" 0 -18000 -05:00 ""
q lvl4json json 4 "" "" 0 0 +00:00 ""
q fixed text "" "Alpha" fixed 0 0 +00:00 ""
q ifixed text "" "alpha" ifixed 1 0 +00:00 ""
q regex text "" "^A[0-9] (alpha|Alpha)|ERR?OR [a-z]+$" regex 0 0 +00:00 ""
q iregex json "" "alpha (beta|x)" iregex 0 0 +00:00 ""
q ranges text "" "" "" 0 0 +00:00 "$(( (T0 - 500) * 1000000 )):$(( (T0 - 300) * 1000000 )),$(( (T0 - 200) * 1000000 )):$(( (T0 - 100) * 1000000 ))"
# stats
awk "$AWK_STATS" < "$I/journal.short" | sort > "$O/stats.out"
echo done
