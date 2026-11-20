#!/usr/bin/env python3
"""raw/v2cmp/rows.json (from summarize-v2cmp.py) -> markdown table rows: metric | v0.1.1 | current | change."""
import json, os, statistics as st
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'raw', 'v2cmp'); rows = json.load(open(R + '/rows.json'))
def cell(v, d=2, scale=1.0):
    v = [x * scale for x in v if x is not None]
    if not v: return None, '-'
    f = '%.' + str(d) + 'f'
    return st.median(v), (f + ' [' + f + '-' + f + ']') % (st.median(v), min(v), max(v))
def row(label, key, d=2, scale=1.0, unit=''):
    r = rows.get(key)
    if not r: return None
    a, ca = cell(r.get('old', []), d, scale); b, cb = cell(r.get('new', []), d, scale)
    if a is None or b is None: ch = 'n/a (not in 0.1.1)' if a is None else '-'
    elif a == 0: ch = '0 -> %.2f' % b
    else: ch = '%+.0f%%' % ((b - a) / a * 100) + (' (%+.2f%s)' % (b - a, unit) if abs(b - a) >= 0.005 else '')
    return f'| {label} | {ca} | {cb} | {ch} |'
spec = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'v2cmp-table.json')))
out = ['| Metric (median [min-max], 3 rounds) | v0.1.1 | current | Change |', '|---|---|---|---|']
for item in spec:
    if isinstance(item, str): out.append(f'| **{item}** | | | |'); continue
    l = row(*item)
    if l: out.append(l)
print('\n'.join(out))
