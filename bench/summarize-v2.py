#!/usr/bin/env python3
"""Summarize bench/raw/v2/ (all rounds pooled per approach) into raw/v2/summary.txt.
median [min-max] (n). Memory: per idle snapshot file, median over its 3 samples, then the median
over rounds. Usage: python3 bench/summarize-v2.py"""
import os, re, glob, statistics as st
V = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'raw', 'v2')
NAMES = {'a': 'A tando', 'b': 'B Kamal 2', 'c': 'C build on server (scripted)', 'd': 'D Podman quadlet (scripted)', 'e': 'E Dokku'}
MB = 1048576
out = []
def p(*a): out.append(' '.join(str(x) for x in a))
def fmt(v, unit='', scale=1, nd=1):
    v = [x / scale for x in v if x is not None]
    if not v: return '-'
    return f"{st.median(v):.{nd}f}{unit} [{min(v):.{nd}f}-{max(v):.{nd}f}] (n={len(v)})"
def rows(path):
    r = []
    if not os.path.exists(path): return r
    for line in open(path):
        f = line.rstrip('\n').split('\t'); d = {'label': f[0]}
        for x in f[1:]:
            for kv in x.split(' '):
                if '=' in kv: k, v = kv.split('=', 1); d[k] = v
        r.append(d)
    return r
def num(rs, pat, key):
    o = []
    for r in rs:
        if re.fullmatch(pat, r['label']) and key in r:
            try: o.append(float(r[key]))
            except ValueError: pass
    return o
def memfile(path):
    acc = {}
    for line in open(path):
        if line.startswith('#'): continue
        f = line.split('\t')
        if len(f) == 3: acc.setdefault(f[0], []).append((int(f[1]), int(f[2])))
    return {k: (st.median(a for a, _ in v), st.median(b for _, b in v)) for k, v in acc.items()}
def platform_anon(mm):
    """anon of what the approach adds besides the app containers/units and the base OS"""
    s = 0
    for k, (_, an) in mm.items():
        if re.search(r'(docker|containerd|caddy|nginx|dokku)\.service$', k) or 'kamal-proxy' in k: s += an
    return s

for x in 'abcde':
    rounds = sorted(glob.glob(os.path.join(V, x, 'round*')))
    if not rounds: continue
    p(f"\n===== {NAMES[x]}  ({len(rounds)} rounds) =====")
    M, D, A, T = [], [], [], []
    for r in rounds:
        M += rows(os.path.join(r, 'measured.tsv')); D += rows(os.path.join(r, 'downtime.tsv'))
        A += rows(os.path.join(r, 'anonpeak.tsv')); T += rows(os.path.join(r, 'times.tsv'))
        n = os.path.join(r, 'notes.txt')
        if os.path.exists(n):
            for l in open(n):
                if l.startswith(('load', 'empty_vm')): p(f"  {os.path.basename(r)} {l.strip()}")
    p("cold wall s:", fmt(num(M, 'cold', 'wall_ms'), 's', 1000), " cpu s:", fmt(num(M, 'cold', 'cpu_ms'), 's', 1000, 2),
      " rx MB:", fmt(num(M, 'cold', 'rx_bytes'), '', MB, 1), " peak MB:", fmt(num(M, 'cold', 'peak_sum'), '', MB, 0))
    p("warm quiet wall s:", fmt(num(M, r'warm-quiet-\d+', 'wall_ms'), 's', 1000))
    if T:
        p("warm time to live s:", fmt(num(T, r'warm-(quiet|loop)-\d+', 'live_s'), 's', 1, 1), " command return s:", fmt(num(T, r'warm-(quiet|loop)-\d+', 'return_s'), 's', 1, 1))
        p("cold time to live s:", fmt(num(T, 'cold', 'live_s'), 's', 1, 1), " verified s:", fmt(num(T, 'cold', 'verified_s'), 's', 1, 1))
        p("warm verified s:", fmt(num(T, r'warm-(quiet|loop)-\d+', 'verified_s'), 's', 1, 1))
        p("rollback live s:", fmt(num(T, r'rollback-.*', 'live_s'), 's', 1, 1), " return s:", fmt(num(T, r'rollback-.*', 'return_s'), 's', 1, 1), " verified s:", fmt(num(T, r'rollback-.*', 'verified_s'), 's', 1, 1))
    p("warm server cpu s:", fmt(num(M, r'warm-quiet-\d+', 'cpu_ms'), 's', 1000, 2))
    p("warm bytes to server KB:", fmt(num(M, r'warm-quiet-\d+', 'rx_bytes'), '', 1024, 0))
    p("warm peak (sum of slice peaks, incl cache) MB:", fmt(num(M, r'warm-quiet-\d+', 'peak_sum'), '', MB, 0))
    ap = [(float(r['anon_peak']) - float(r['anon_before'])) for r in A if r.get('anon_peak') and r.get('anon_before')]
    p("warm anon peak MB (absolute):", fmt(num(A, r'anonpeak-\d+', 'anon_peak'), '', MB, 0), " rise above idle MB:", fmt(ap, '', MB, 0))
    p("warm under load: failed:", fmt(num(D, r'warm-loop-\d+', 'failed'), '', 1, 0), " longest gap ms:", fmt(num(D, r'warm-loop-\d+', 'longest_gap_ms'), '', 1, 0),
      " p95 ms:", fmt(num(D, r'warm-loop-\d+', 'p95_ms'), '', 1, 0), " wall s:", fmt(num(D, r'warm-loop-\d+', 'wall_ms'), 's', 1000))
    if num(D, 'three-deploys', 'failed'):
        p("3 consecutive deploys under one loop: failed:", fmt(num(D, 'three-deploys', 'failed'), '', 1, 0), " gap ms:", fmt(num(D, 'three-deploys', 'longest_gap_ms'), '', 1, 0))
    p("rollback wall s:", fmt(num(M, r'rollback-quiet-\d+', 'wall_ms') + num(D, r'rollback-loop-.*', 'wall_ms'), 's', 1000),
      " failed under load:", fmt(num(D, r'rollback-loop-.*', 'failed'), '', 1, 0), " gap ms:", fmt(num(D, r'rollback-loop-.*', 'longest_gap_ms'), '', 1, 0))
    p("broken release: rc:", [r.get('rc') for r in D if r['label'] == 'broken'], " wall s:", fmt(num(D, 'broken', 'wall_ms'), 's', 1000),
      " failed:", fmt(num(D, 'broken', 'failed'), '', 1, 0))
    for lab, pat in (('tando ls', r'ls-\d+'), ('tando status', r'status-\d+'), ('tando ls --json', r'lsjson-\d+'), ('tando ls, 10 apps', r'ls10-\d+'),
                     ('kamal details', r'details-\d+'), ('ssh docker ps', r'dockerps-\d+'), ('ssh docker stats', r'dockerstats-\d+'),
                     ('ssh podman ps', r'podmanps-\d+'), ('ssh podman stats', r'podmanstats-\d+'), ('dokku ps:report', r'dokkups-\d+'), ('dokku apps:list', r'dokkulist-\d+'),
                     ('host setup again', 'host-setup-again')):
        v = num(M, pat, 'cpu_ms')
        if v: p(f"status [{lab}] server cpu ms:", fmt(v, '', 1, 0), " wall ms:", fmt(num(M, pat, 'wall_ms'), '', 1, 0))
    for name in ('mem-1-zero-apps', 'mem-1-docker-zero-apps', 'mem-4-proxy-zero-apps', 'mem-2-one-app', 'mem-3-three-apps', 'mem-4-five-apps', 'mem-5-ten-apps'):
        fs = [f for f in (os.path.join(r, name + '.tsv') for r in rounds) if os.path.exists(f)]
        if not fs: continue
        mms = [memfile(f) for f in fs]; mms = [m for m in mms if 'TOTAL' in m]
        p(f"{name}: total anon MB {fmt([m['TOTAL'][1] for m in mms], '', MB, 1)}; memory.current MB {fmt([m['TOTAL'][0] for m in mms], '', MB, 0)};"
          f" platform anon MB {fmt([platform_anon(m) for m in mms], '', MB, 1)}")
    for r in rounds[:1]:
        for f in ('disk.txt', 'disk.tsv', 'app-mem.txt', 'watch-cpu.tsv'):
            fp = os.path.join(r, f)
            if os.path.exists(fp): p(f"-- {os.path.basename(r)}/{f}:\n" + open(fp).read().rstrip()[:3000])

gos = sorted(glob.glob(os.path.join(V, 'a-go', 'run*', 'notes.txt')))
for g in gos: p("tando go:", ' '.join(l.strip() for l in open(g)))
for r in sorted(glob.glob(os.path.join(V, 'a', 'round*'))):
    fp = os.path.join(r, 'watch-cpu.tsv')
    if os.path.exists(fp): p(f"tando-watch {os.path.basename(r)}: " + open(fp).read().replace('\n', '; ')[:600])
p("\n===== empty VM -> first live app =====")
for x in 'abcde':
    fs = sorted(glob.glob(os.path.join(V, 'bare', f'{x}-*', 'steps.tsv'))) + sorted(glob.glob(os.path.join(V, x, 'round*', 'steps.tsv')))
    tot, cmds = [], set()
    for f in fs:
        s = [l.rstrip('\n').split('\t') for l in open(f) if l.strip()]
        steps = [l for l in s if l[0] == 'step' or (len(l) == 3)]
        # run-bare.sh lines: step label ms rc / file label 0 0 ; run-e-dokku.sh lines: label ms rc
        ms = [int(l[2]) if l[0] == 'step' else int(l[1]) for l in steps if not (l[0] == 'step' and l[1] in ('4-domain-add', '3-up'))]
        if any(l[0] == 'step' and l[1] == '3-up' for l in steps):   # tando: count `up` until live, not until verified
            tt = rows(os.path.join(os.path.dirname(f), 'times.tsv')); lv = num(tt, 'cold', 'live_s')
            ms.append(int(lv[0] * 1000) if lv else 0)
        if steps: tot.append(sum(ms) / 1000); cmds.add((len(ms), len([l for l in s if l[0] == 'file'])))
        p(f"  {x} {os.path.relpath(f, V)}: " + ', '.join(f"{(l[1] if l[0] in ('step','file') else l[0])}={(l[2] if l[0]=='step' else ('file' if l[0]=='file' else l[1]))}" for l in s))
    if tot: p(f"{NAMES[x]}: empty VM to live s {fmt(tot, 's', 1, 0)}; (commands, hand-written files) {sorted(cmds)}")

open(os.path.join(V, 'summary.txt'), 'w').write('\n'.join(out) + '\n')
print('\n'.join(out))
