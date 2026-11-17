#!/usr/bin/env python3
"""Per-phase seconds from deploy logs in bench/raw/<x>/*.log -> raw/phases.txt.
A (tando): client phases from the boxed output (build/stage/upload, whole seconds) and server
phases (copy/preflight/switch/verify, 0.1 s). B (Kamal): sums of Kamal's own per-command
"Finished in" times: build = buildx build+push, pull = docker pull on the server, switch =
docker run + kamal-proxy deploy (health check and traffic switch); total from "Finished all in".
C and D: the phase=seconds lines their scripts print."""
import os, re, glob, statistics as st
RAW = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'raw')
out = []

def med(v): return f"{st.median(v):.2f} [{min(v):.2f}-{max(v):.2f}] (n={len(v)})" if v else '-'

def tando(log):
    t = open(log).read(); d = {}
    for k in ('build', 'stage', 'upload', 'copy', 'preflight', 'switch', 'verify'):
        m = re.search(r'[✓✗] \d/7\s+%s\s+([\d.]+)s' % k, t)
        if m: d[k] = float(m.group(1))
    m = re.search(r'(\d+) files changed, ([\d.]+ [KMG]?B) sent', t)
    if m: d['files_changed'] = float(m.group(1)); d['rsync_sent'] = m.group(2)
    return d

def kamal(log):
    t = open(log).read(); cmds = {}; d = {'build': 0, 'pull': 0, 'switch': 0, 'other': 0}
    for m in re.finditer(r'INFO \[(\w+)\] Running (.*?) on ', t): cmds[m.group(1)] = m.group(2)
    for m in re.finditer(r'INFO \[(\w+)\] Finished in ([\d.]+) seconds', t):
        c = cmds.get(m.group(1), ''); s = float(m.group(2))
        if 'buildx build' in c: d['build'] += s
        elif c.startswith('docker pull'): d['pull'] += s
        elif 'kamal-proxy deploy' in c or c.startswith('docker run --detach --restart unless-stopped --name bench'): d['switch'] += s
        else: d['other'] += s
    m = re.findall(r'Finished all in ([\d.]+) seconds', t)
    if m: d['kamal_total'] = float(m[-1])
    return d

def kv(log):
    d = {}
    for line in open(log):
        m = re.match(r'^(\w+)=([\d.]+)$', line.strip())
        if m: d[m.group(1)] = float(m.group(2))
    return d

for x, fn in (('a', tando), ('b', kamal), ('c', kv), ('d', kv)):
    dd = os.path.join(RAW, x)
    if not os.path.isdir(dd): continue
    out.append(f"===== {x} =====")
    groups = {'cold': ['cold'], 'warm': [], 'rollback': [], 'broken': ['broken']}
    for f in sorted(glob.glob(os.path.join(dd, '*.log'))):
        b = os.path.basename(f)[:-4]
        if b.startswith('warm-'): groups['warm'].append(b)
        if b.startswith('rollback-'): groups['rollback'].append(b)
    for g, labels in groups.items():
        rows = [fn(os.path.join(dd, l + '.log')) for l in labels if os.path.exists(os.path.join(dd, l + '.log'))]
        if not rows: continue
        keys = sorted({k for r in rows for k in r if isinstance(r[k], float)})
        out.append(f"{g}: " + '; '.join(f"{k} {med([r[k] for r in rows if k in r])}" for k in keys))
        if x == 'a' and g == 'warm': out.append("warm rsync sent: " + ', '.join(sorted({r.get('rsync_sent', '?') for r in rows})))
open(os.path.join(RAW, 'phases.txt'), 'w').write('\n'.join(out) + '\n')
print('\n'.join(out))
