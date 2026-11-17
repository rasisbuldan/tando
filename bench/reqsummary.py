#!/usr/bin/env python3
"""Summarize a reqloop.py file: requests, ok (200), failed, longest gap between consecutive 200
responses (end of one to end of the next, ms), latency p50/p95/max of the 200s (ms).
Optional: --expect-change A B  report first time the body changed is not available (status only)."""
import sys
rows = []
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) == 3: rows.append((int(p[0]), p[1], float(p[2])))
ok = [r for r in rows if r[1] == '200']
bad = [r for r in rows if r[1] != '200']
gap, prev = 0, None
for t, c, d in rows:
    if c == '200':
        end = t + d
        if prev is not None: gap = max(gap, end - prev)
        prev = end
lat = sorted(r[2] for r in ok)
q = lambda p: lat[min(len(lat) - 1, int(p * len(lat)))] if lat else 0
dur = (rows[-1][0] - rows[0][0]) / 1000 if rows else 0
print(f"duration_s={dur:.1f} requests={len(rows)} ok={len(ok)} failed={len(bad)} "
      f"longest_gap_ms={gap:.0f} p50_ms={q(.5):.1f} p95_ms={q(.95):.1f} max_ms={(lat[-1] if lat else 0):.1f} "
      f"bad_codes={','.join(sorted(set(r[1] for r in bad))) or '-'}")
