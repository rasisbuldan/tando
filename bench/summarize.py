#!/usr/bin/env python3
"""Summarize bench/raw/<a|b|c|d>/ into bench/raw/summary.txt: median [min-max] (n) per metric.
Usage: python3 bench/summarize.py"""
import os, re, glob, statistics as st

RAW = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'raw')
NAMES = {'a': 'A tando', 'b': 'B Kamal 2', 'c': 'C build on server', 'd': 'D Podman quadlet (scripted)'}
out = []
def p(*a): out.append(' '.join(str(x) for x in a))

def fmt(v, unit='', scale=1, nd=1):
    if not v: return '-'
    v = [x / scale for x in v]
    m = st.median(v)
    if len(v) == 1: return f"{m:.{nd}f}{unit} (n=1)"
    return f"{m:.{nd}f}{unit} [{min(v):.{nd}f}-{max(v):.{nd}f}] (n={len(v)})"

def tsv(path):
    rows = []
    if not os.path.exists(path): return rows
    for line in open(path):
        f = line.rstrip('\n').split('\t')
        d = {'label': f[0]}
        for x in f[1:]:
            for kv in x.split(' '):
                if '=' in kv:
                    k, v = kv.split('=', 1); d[k] = v
        rows.append(d)
    return rows

def num(rows, pat, key):
    return [float(r[key]) for r in rows if re.fullmatch(pat, r['label']) and key in r and r[key] not in ('', None)]

def mem(path):
    """median over samples of (current, anon+shmem) per cgroup"""
    if not os.path.exists(path): return {}
    acc = {}
    for line in open(path):
        if line.startswith('#'): continue
        f = line.split('\t')
        if len(f) == 3: acc.setdefault(f[0], []).append((int(f[1]), int(f[2])))
    return {k: (st.median(a for a, _ in v), st.median(b for _, b in v)) for k, v in acc.items()}

def idle_cpu(path):
    if not os.path.exists(path): return None
    m = re.search(r'idle cpu: (\d+) ms', open(path).read())
    return int(m.group(1)) if m else None

MB = 1048576
for k in 'abcd':
    d = os.path.join(RAW, k)
    if not os.path.isdir(d): continue
    p(f"\n===== {NAMES[k]} =====")
    m = tsv(os.path.join(d, 'measured.tsv')); dt = tsv(os.path.join(d, 'downtime.tsv'))
    p("cold wall s:", fmt(num(m, 'cold', 'wall_ms'), 's', 1000, 1), " cpu s:", fmt(num(m, 'cold', 'cpu_ms'), 's', 1000, 2),
      " rx MB:", fmt(num(m, 'cold', 'rx_bytes'), '', MB, 2), " peak MB:", fmt(num(m, 'cold', 'peak_sum'), '', MB, 0))
    p("warm quiet wall s:", fmt(num(m, r'warm-quiet-\d+', 'wall_ms'), 's', 1000, 1))
    p("warm quiet server cpu s:", fmt(num(m, r'warm-quiet-\d+', 'cpu_ms'), 's', 1000, 2))
    p("warm quiet rx bytes (eth0) KB:", fmt(num(m, r'warm-quiet-\d+', 'rx_bytes'), '', 1024, 0))
    p("warm quiet peak (sum of slice peaks) MB:", fmt(num(m, r'warm-quiet-\d+', 'peak_sum'), '', MB, 0))
    p("warm loop wall s:", fmt(num(dt, r'warm-loop-\d+', 'wall_ms'), 's', 1000, 1))
    p("warm loop failed requests:", fmt(num(dt, r'warm-loop-\d+', 'failed'), '', 1, 0),
      " longest gap ms:", fmt(num(dt, r'warm-loop-\d+', 'longest_gap_ms'), '', 1, 0),
      " p95 ms:", fmt(num(dt, r'warm-loop-\d+', 'p95_ms'), '', 1, 0), " max ms:", fmt(num(dt, r'warm-loop-\d+', 'max_ms'), '', 1, 0))
    for lab in ('baseline-idle', 'npmci-loop', 'broken'):
        for r in dt:
            if r['label'] == lab: p(f"{lab}:", '\t'.join(f"{a}={b}" for a, b in r.items() if a != 'label'))
    for r in m:
        if r['label'] in ('npmci-quiet', 'redeploy', 'fixed'): p(f"{r['label']}:", '\t'.join(f"{a}={b}" for a, b in r.items() if a != 'label'))
    p("rollback quiet wall s:", fmt(num(m, r'rollback-quiet-\d+', 'wall_ms'), 's', 1000, 1), " cpu s:", fmt(num(m, r'rollback-quiet-\d+', 'cpu_ms'), 's', 1000, 2))
    p("rollback loop failed:", fmt(num(dt, r'rollback-loop-.*', 'failed'), '', 1, 0), " gap ms:", fmt(num(dt, r'rollback-loop-.*', 'longest_gap_ms'), '', 1, 0),
      " wall s:", fmt(num(dt, r'rollback-loop-.*', 'wall_ms'), 's', 1000, 1))
    for lab, pat in (('tando ls', r'ls-\d+'), ('tando status', r'status-\d+'), ('agent status via docker exec', r'agent-status-\d+'),
                     ('kamal details', r'details-\d+'), ('ssh docker ps', r'dockerps-\d+'), ('ssh docker stats --no-stream', r'dockerstats-\d+'),
                     ('ssh podman ps', r'podmanps-\d+'), ('ssh podman stats --no-stream', r'podmanstats-\d+')):
        v = num(m, pat, 'cpu_ms')
        if v: p(f"status query [{lab}] server cpu ms:", fmt(v, '', 1, 0), " wall ms:", fmt(num(m, pat, 'wall_ms'), '', 1, 0))
    for f in sorted(glob.glob(os.path.join(d, 'mem-*.tsv'))):
        mm = mem(f); tot = mm.get('TOTAL')
        if not tot: continue
        p(f"-- {os.path.basename(f)}: container total current {tot[0]/MB:.1f} MB, anon+shmem {tot[1]/MB:.1f} MB; idle cpu {idle_cpu(f)} ms/20 s")
        for cg, (cur, an) in sorted(mm.items()):
            if cg in ('TOTAL', 'system.slice', 'machine.slice'): continue
            if cur > 512 * 1024: p(f"     {cg:60s} current {cur/MB:7.1f} MB  anon+shmem {an/MB:7.1f} MB")
    for f in ('disk.tsv', 'disk.txt', 'app-mem.txt'):
        fp = os.path.join(d, f)
        if os.path.exists(fp): p(f"-- {f}:\n" + open(fp).read().rstrip())

open(os.path.join(RAW, 'summary.txt'), 'w').write('\n'.join(out) + '\n')
print('\n'.join(out))
