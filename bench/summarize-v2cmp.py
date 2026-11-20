#!/usr/bin/env python3
"""raw/v2cmp/{old,new}/round*/ -> raw/v2cmp/summary.txt: per metric, median [min-max] (n) for each tree."""
import os, re, glob, json, statistics as st, sys
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'raw', 'v2cmp')
MB = 1048576
def med(v, f='%.2f'):
    v = [x for x in v if x is not None]
    return '-' if not v else (f + ' [' + f + '-' + f + '] (n=%d)') % (st.median(v), min(v), max(v), len(v))
def rd(p):
    try: return open(p).read()
    except OSError: return ''
def kvline(line):
    return dict(x.split('=', 1) for x in line.split('\t')[1:] if '=' in x)
def mem(path):  # median over samples of {cgroup: (current, anon)}
    samples, cur = [], None
    for l in rd(path).splitlines():
        if l.startswith('# sample'): cur = {}; samples.append(cur)
        elif cur is not None and '\t' in l:
            k, a, b = l.split('\t'); cur[k] = (int(a), int(b))
    out = {}
    for k in set(x for s in samples for x in s):
        out[k] = tuple(st.median(s[k][i] for s in samples if k in s) for i in (0, 1))
    m = re.search(r'idle cpu: (\d+) ms', rd(path)); return out, int(m.group(1)) if m else None
def sumg(d, prefix):
    return tuple(sum(v[i] for k, v in d.items() if k == prefix or k.startswith(prefix + '/') and k.count('/') == prefix.count('/') + 1) for i in (0, 1))
rows = {}
def add(tree, metric, val):
    rows.setdefault(metric, {}).setdefault(tree, []).append(val)
for tree in ('old', 'new'):
    for rd_ in sorted(glob.glob(f'{R}/{tree}/round*')):
        P = lambda f: os.path.join(rd_, f)
        notes = rd(P('notes.txt'))
        for l in notes.splitlines():
            m = re.match(r'load ([0-9.]+)[ ,]', l)
            if m: add(tree, 'host load avg (1 min) at round points', float(m.group(1)))
            m = re.match(r'host_setup_cpu_ms (\d+)', l)
            if m: add(tree, 'host setup: server CPU s', int(m.group(1)) / 1000)
        steps = {l.split('\t')[1]: int(l.split('\t')[2]) for l in rd(P('steps.tsv')).splitlines() if l.startswith('step')}
        if '2-host-setup' in steps: add(tree, 'host setup: wall s', steps['2-host-setup'] / 1000)
        times = {l.split('\t')[0]: kvline(l) for l in rd(P('times.tsv')).splitlines()}
        meas = {l.split('\t')[0]: kvline(l) for l in rd(P('measured.tsv')).splitlines()}
        def tl(name, tag, ph=True):
            t = rd(P(name + '.tlog'))
            for k in ('build', 'stage', 'upload', 'copy', 'preflight', 'switch'):
                m = re.search(r'[✓✗] \d/7\s+%s\s+([\d.]+)s' % k, t)
                if m and ph: add(tree, f'{tag}: phase {k} s', float(m.group(1)))
            m = re.search(r'CLIENT wall=([\d.]+) user=([\d.]+) sys=([\d.]+) maxrss_kb=(\d+)', t)
            if m:
                add(tree, f'{tag}: client CPU (user+sys) s', float(m.group(2)) + float(m.group(3)))
                add(tree, f'{tag}: client max RSS MB', int(m.group(4)) / 1024)
            m = re.search(r'(\d+) files changed, ([\d.]+) ([KMG]?)B sent', t)
            if m: add(tree, f'{tag}: rsync sent (bytes)', float(m.group(2)) * {'': 1, 'K': 1024, 'M': MB, 'G': 1024 * MB}[m.group(3)])
        for name, tag in [('cold', 'cold up')] + [(f'warm-quiet-{i}', 'warm') for i in (1, 2)] + [('warm-loop-1', 'warm(loop)')]:
            if name in times:
                t = times[name]
                if t.get('live_s', '-') != '-': add(tree, f'{tag}: live (command output) s', float(t['live_s']))
                if t.get('verified_s', '-') != '-': add(tree, f'{tag}: verified (soak over) s', float(t['verified_s']))
            tl(name, tag)
        for name in ['cold'] + [f'warm-quiet-{i}' for i in (1, 2)]:
            m = meas.get(name)
            if not m: continue
            tag = 'cold up' if name == 'cold' else 'warm'
            if 'cpu_ms' in m: add(tree, f'{tag}: server CPU s', int(m['cpu_ms']) / 1000)
            if 'rx_bytes' in m: add(tree, f'{tag}: bytes to server (eth0 rx)', int(m['rx_bytes']))
            if m.get('peak_sum', '').isdigit(): add(tree, f'{tag}: peak memory (sum of slice peaks, incl. page cache) MB', int(m['peak_sum']) / MB)
        for l in rd(P('anonpeak.tsv')).splitlines():
            m = kvline(l)
            if 'anon_peak' in m: add(tree, 'warm: anon+shmem peak MB', int(m['anon_peak']) / MB); add(tree, 'warm: anon+shmem before MB', int(m['anon_before']) / MB)
        for l in rd(P('downtime.tsv')).splitlines():
            m = re.search(r'requests=(\d+) ok=(\d+) failed=(\d+) longest_gap_ms=(\d+) p50_ms=([\d.]+) p95_ms=([\d.]+) max_ms=([\d.]+)', l)
            if m:
                add(tree, 'loop: requests', int(m[1])); add(tree, 'loop: failed requests', int(m[3])); add(tree, 'loop: longest gap ms', int(m[4]))
                add(tree, 'loop: p95 latency ms', float(m[6])); add(tree, 'loop: max latency ms', float(m[7]))
        for l in rd(P('measured.tsv')).splitlines():
            m = re.match(r'cmd-(.*)-(\d)\t', l)
            if m:
                k = kvline(l); c = m[1].replace('-', ' ').replace('  ', ' ')
                if k.get('rc') != '0': continue
                add(tree, f'tando {c}: laptop wall s', int(k['wall_ms']) / 1000); add(tree, f'tando {c}: server CPU s', int(k['cpu_ms']) / 1000)
        for n in ('1app', '3apps'):
            d, idle = mem(P(f'mem-{n}.tsv'))
            if not d: continue
            add(tree, f'idle {n}: whole server anon+shmem MB', d['TOTAL'][1] / MB); add(tree, f'idle {n}: whole server memory.current MB', d['TOTAL'][0] / MB)
            if idle is not None: add(tree, f'idle {n}: server CPU ms per 20 s', idle)
            for lab, key in (('tandod', 'system.slice/tandod.service'), ('caddy', 'system.slice/caddy.service'), ('tando.slice (apps)', 'tando.slice'),
                             ('journald', 'system.slice/systemd-journald.service'), ('sshd', 'system.slice/ssh.service'), ('user.slice (ssh sessions)', 'user.slice')):
                if key in d: add(tree, f'idle {n}: {lab} anon MB', d[key][1] / MB)
        # disk
        t = rd(P('disk.txt'))
        for l in t.splitlines():
            m = re.match(r'rel (\S+) apparent (\d+) du (\d+)', l)
            if m: add(tree, 'disk: per release (apparent, bytes)', int(m[2]))
            m = re.match(r'(assets_dir|opt_tando|releases|incoming|assets|assetlog)\t(\d+)', l)
            if m: add(tree, f'disk: {m[1]} (bytes)', int(m[2]))
        m = re.search(r'releases: (\d+)', t)
        if m: add(tree, 'disk: releases kept', int(m[1]))
        def jd(f):
            m = re.search(r'take up ([\d.]+)([KMG]) ', rd(P(f)))
            return float(m[1]) * {'K': 1024, 'M': MB, 'G': 1024 * MB}[m[2]] if m else None
        def vl(f):
            m = re.search(r'^(\d+)\t/var/log$', rd(P(f)), re.M); return int(m[1]) if m else None
        a, b = vl('log-before.txt'), vl('log-after.txt')
        if a is not None and b is not None: add(tree, 'logs: /var/log growth per 100 requests (bytes; Caddy access log + journal files)', b - a)
        # tando-watch
        w = rd(P('watch-journal.txt'))
        cons = re.findall(r'Consumed ([\d.]+)(ms|s) CPU time', w)
        for x, u in cons: add(tree, 'tando-watch: CPU per run ms', float(x) * (1 if u == 'ms' else 1000))
        add(tree, 'tando-watch: runs seen in window', len(cons))
out = []
for metric in sorted(rows, key=lambda m: m):
    r = rows[metric]
    out.append(f'{metric}\told: {med(r.get("old", []))}\tnew: {med(r.get("new", []))}')
open(R + '/summary.txt', 'w').write('\n'.join(out) + '\n')
print('\n'.join(out))
json.dump(rows, open(R + '/rows.json', 'w'))
