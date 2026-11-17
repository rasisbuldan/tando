#!/usr/bin/env python3
# Deterministic corpora for the golden tests of srv/logs: short-unix journal lines (error scan,
# stats), Caddy access lines (request log), journalctl JSON entries (tando logs). Hostile on
# purpose: escapes, control bytes, invalid UTF-8, long lines, missing fields.
import json, random, sys, os
out = sys.argv[1]
R = random.Random(20261116)
T0 = 1794587950

def w(name, data):
    with open(os.path.join(out, name), 'wb') as f:
        f.write(data)

# ---------------- short-unix journal lines ----------------
def hexs(n): return ''.join(R.choice('0123456789abcdef') for _ in range(n))
def uuid(): return '-'.join([hexs(8), hexs(4), hexs(4), hexs(4), hexs(12)])
REL = ['20261115-013512', '20261116-090000-2']
node_frames_app = ['    at nodeErr (/opt/tando/apps/boom/releases/%s/server.js:%d:%d)' % (REL[0], 12, 7),
  '    at Server.<anonymous> (/opt/tando/apps/boom/releases/%s/server.js:%d:%d)' % (REL[1], 40, 3),
  '    at handler (file:///opt/tando/apps/boom/releases/%s/lib/h.mjs:%d:%d)' % (REL[0], 9, 1),
  '    at Object.run (/srv/app/src/run.js:%d:%d)' % (77, 5),
  '    at async load (/home/u/x/releases/2026-11-15/y.js:3:4)',
  '    at fn%s (/app/m%s.js:1:2)' % (hexs(10), R.randint(0, 999)),
  '\tat tabbed (/srv/t.js:1:1)']
node_frames_lib = ['    at Layer.handle (/srv/node_modules/express/lib/router/layer.js:95:5)',
  '    at process.processTicksAndRejections (node:internal/process/task_queues:95:5)',
  '    at new Promise (<anonymous>)', '    at Module._compile (internal/modules/cjs/loader.js:1:1)',
  '    at x (internal/y.js:1:1)']
node_starts = ['TypeError: Cannot read properties of null (reading \'foo\')', 'Error: connect ECONNREFUSED 127.0.0.1:5432',
  'Uncaught RangeError: Invalid array length', 'Unhandled SyntaxError: Unexpected token } in JSON at position 42',
  'Uncaught Unhandled Error: double', 'errors.CustomError [ERR_X]: bad', 'ValidationException: field id=%d' % 5,
  'Error', 'TypeError:', 'my.pkg.Thing$Error: x']
py_app = ['  File "/srv/app/views.py", line 41, in checkout', '  File "/opt/tando/apps/api/releases/%s/app/models.py", line 7, in save' % REL[0],
  '  File "/srv/app/x.py", line %d, in f%d' % (R.randint(1, 900), 3)]
py_lib = ['  File "/usr/lib/python3.12/site-packages/django/core/handlers.py", line 47, in inner',
  '  File "/venv/lib/python3.12/dist-packages/x.py", line 1, in y', '  File "/usr/lib/python3.12/json/decoder.py", line 9, in z']
py_end = ['KeyError: \'total\'', 'ValueError: invalid literal for int() with base 10: \'abc\'', 'django.db.utils.OperationalError: could not connect',
  'StopIteration', 'Exception:', 'RuntimeError: x 0xdeadbeef id 9f86d081884c7d65']
go_first = ['panic: runtime error: index out of range [5] with length 3', 'fatal error: concurrent map writes',
  'panic: user %s not found' % uuid(), 'panic: 0x1f boom 12345678abc']
go_frames = ['main.handler(0xc000012345)', 'runtime.gopanic({0x4a, 0x5})', 'net/http.HandlerFunc.ServeHTTP(0x0, {0x1, 0x2})',
  'github.com/x/y.(*T).Do(0xc0001, 0x2)', 'main.(*server).serve(...)']
plain_err = ['ERROR db timeout after %d ms', 'error: could not open /var/data/%s.db', '[api] TypeError: x is %d',
  '12:00:01 [api] ValidationError: bad request %s', '{"level":50,"msg":"boom %d"}', '{"level": 60}', 'CRITICAL disk full on /dev/sda%d',
  'Fatal: %s', 'unhandled rejection id=%s', 'panicking? no: %d', 'an exception happened in job %s', 'Traceback (not really) %d',
  'x-error-y %d', 'errors %d', 'TERROR %d', 'request failed: Error: wrapped %d']
plain_ok = ['GET /health 200 %d ms', 'listening on 3000', 'info: started worker %d', 'user %s logged in', 'cache hit ratio %d%%',
  'interroR %d', '{"level":30,"msg":"ok %d"}']
hostile = ['ERROR ctl \x01\x02\x1b[31mred\x7f end', 'ERROR tab\there\tand %d', 'ERROR utf8 caf\xc3\xa9 %d',
  'ERROR c1 \xc2\x9b raw \x9b %d', 'ERROR invalid \xff\xfe %d', 'ERROR ' + 'long ' * 900, 'ERROR ' + 'x' * 300,
  'TypeError: ' + 'y' * 5000, 'ERROR id ' + '-'.join([hexs(8)] * 3) + ' and ' + uuid(), 'ERROR 00x12 0xZZ 0x 0xABCdef9',
  'ERROR deadbeefcafe12 and xdeadbeefcafe12y deadbeefcafe12', 'ERROR <id>-<id> literal %d', 'ERROR ' + hexs(7) + '1 ' + hexs(40)]

def fmtv(s):
    return s % R.randint(0, 99999) if '%d' in s else (s % hexs(12) if '%s' in s else s)

lines = []
ts = float(T0)
pids = [101, 102, 4711]
def emit(msg, pid=None, ident=None, dt=None):
    global ts
    ts += dt if dt is not None else R.choice([0.0, 0.001, 0.01, 0.2, 1.0, 2.5])
    if pid is None: pid = R.choice(pids)
    ident = ident or R.choice(['node', 'python3', 'app', 'tando-boom'])
    lines.append(('%.6f host %s[%d]: ' % (ts, ident, pid)).encode() + (msg.encode('latin-1') if isinstance(msg, str) else msg))

for ev in range(1600):
    k = R.random()
    pid = R.choice(pids)
    if k < 0.18:
        emit(R.choice(node_starts), pid)
        for _ in range(R.randint(0, 12)):
            emit(R.choice(node_frames_app + node_frames_lib), pid, dt=R.choice([0, 0, 0.1, 3]))
        if R.random() < 0.1: emit('Caused by: Error: inner', pid, dt=0)
    elif k < 0.32:
        if R.random() < 0.2: emit('ERROR Exception in handler', pid)
        emit('Traceback (most recent call last):', pid, dt=0 if R.random() < 0.5 else None)
        for _ in range(R.randint(0, 6)):
            emit(R.choice(py_app + py_lib), pid, dt=0); emit('    ' + R.choice(['total = cart["total"]', 'x()', 'return f(1)']), pid, dt=0)
        if R.random() < 0.2:
            emit(R.choice(py_end), pid, dt=0); emit('', pid, dt=0)
            emit(R.choice(['During handling of the above exception, another exception occurred:', 'The above exception was the direct cause of the following exception:']), pid, dt=0)
            emit('', pid, dt=0); emit('Traceback (most recent call last):', pid, dt=0); emit(R.choice(py_app), pid, dt=0)
        emit(R.choice(py_end), pid, dt=0)
        if R.random() < 0.2: emit('more: text after', pid, dt=0)
    elif k < 0.42:
        emit(R.choice(go_first), pid)
        emit('', pid, dt=0); emit('goroutine %d [running]:' % R.randint(1, 50), pid, dt=0)
        for _ in range(R.randint(1, 6)):
            emit(R.choice(go_frames), pid, dt=0); emit('\t/home/dev/app/main.go:%d +0x%s' % (R.randint(1, 300), hexs(2)), pid, dt=0)
        if R.random() < 0.5: emit('created by main.main', pid, dt=0)
        emit('[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x0]', pid, dt=0)
        emit('exit status %d' % R.randint(1, 3), pid, dt=0)
    elif k < 0.62:
        emit(fmtv(R.choice(plain_err)), pid)
    elif k < 0.70:
        emit(fmtv(R.choice(hostile)), pid)
    elif k < 0.74:
        emit('Suppressed %d messages from tando-boom.service' % R.randint(1, 9999), 77, 'systemd-journald')
    elif k < 0.76:
        lines.append(b'-- cursor: s=' + hexs(32).encode() + b';i=' + hexs(4).encode())
    elif k < 0.78:
        lines.append(('%.6f host kernel: no pid here ERROR' % ts).encode())
    elif k < 0.79:
        lines.append(b'   continuation ERROR line')
    elif k < 0.80:   # a very long trace (NL beyond 30 and 400)
        emit('TypeError: long trace', pid)
        for i in range(R.choice([35, 450])): emit('    at f%d (/srv/a.js:1:1)' % i, pid, dt=0)
    else:
        emit(fmtv(R.choice(plain_ok)), pid)
w('journal.short', b'\n'.join(lines) + b'\n')

# existing groups.tsv for the merge
G = []
G.append('\t'.join(['5dc0ff13', '7', str(T0 - 86400 * 9), str(T0 - 86400 * 8), '-', 'line', 'error line', 'line|old', 'old', '%d:3,%d:4' % ((T0 - 86400 * 8) // 3600 * 3600, T0 // 3600 * 3600)]))
G.append('short\tline\tonly')
G.append('')
G.append('\t'.join(['abcdef01', 'x', 'notnum', '', 'r', 'node', 'L', 'fp', 'title', '', 'extra', 'fields']))
G.append('\t'.join(['abcdef02', '2', str(T0), str(T0 + 5), 'r', 'py', 'L2', 'fp2', 't2', '%d:1,%d:1,bad,%d' % (T0 // 3600 * 3600, T0 // 3600 * 3600, T0)]))
G.append('\t'.join(['abcdef02', '3', str(T0), str(T0 + 9), 'r', 'py', 'L2b', 'fp2', 't2', '']))
w('groups.tsv', ('\n'.join(G) + '\n').encode())

# ---------------- Caddy access lines ----------------
NOW = T0 + 3600
def req_line(t, method='GET', uri='/', status=200, dur=0.001, size=12, client=True, order=None, raw_uri=False):
    rq = {'remote_ip': '10.0.0.%d' % R.randint(1, 9), 'remote_port': '4123', 'proto': 'HTTP/1.1', 'method': method, 'host': 'boom.localhost'}
    if client: rq['client_ip'] = '192.168.1.%d' % R.randint(1, 9)
    rq['uri'] = uri
    d = {'level': 'info', 'ts': t, 'logger': 'http.log.access.log0', 'msg': 'handled request', 'request': rq,
         'bytes_read': 0, 'user_id': '', 'duration': dur, 'size': size, 'status': status}
    s = json.dumps(d, separators=(',', ':'), ensure_ascii=False)
    return s.encode('utf-8', 'surrogatepass')
paths = ['/', '/health', '/users/%d' % 5, '/users/%d/orders/%s', '/api/fail/%d', '/static/app.%s.js', '/a/b/c', 'nopath',
  '/x?-', '/q/%d?-', '/' + 'seg/' * 40, '/emoji/\U0001F600', '/café', '/c1/\u0085', '/esc/\u001b[2J', '/nl/a\nb', '/tab/\t',
  '/quote/"x"', '/back/\\x', '/slash\\/', '/' + 'z' * 5000, '/uu/' + uuid(), '/hex/' + hexs(15), '/hex/' + hexs(16).upper(), '//double', '/trail/']
methods = ['GET', 'POST', 'PUT', 'DELETE', 'G\u0007T', 'PATCH']
reql = []
for i in range(5000):
    t = NOW - R.uniform(-5, 7200)
    p = R.choice(paths)
    if '%d' in p and '%s' in p: p = p % (R.randint(0, 999), hexs(16))
    elif '%d' in p: p = p % R.randint(0, 99999)
    elif '%s' in p: p = p % hexs(R.choice([8, 16, 20]))
    st = R.choice([200] * 10 + [201, 204, 301, 304, 400, 404, 404, 418, 499, 500, 502, 503, 0, 0])
    dur = R.choice([R.uniform(0, 0.00001), R.uniform(0, 0.05), R.uniform(0, 2), 0.0, 1e-9, 12.5])
    m = R.choice(methods)
    k = R.random()
    if k < 0.01: reql.append(b'not json at all ERROR'); continue
    if k < 0.02: reql.append(b''); continue
    if k < 0.03: reql.append(b'{"level":"info","ts":%d,"msg":"no request","status":500,"duration":0.1}' % int(t)); continue
    if k < 0.04: reql.append(b'{"level":"info","ts":%f,"request":{"remote_ip":"1.2.3.4"},"duration":0.2,"size":5,"status":0}' % t); continue
    if k < 0.05: reql.append(b'{"level":"info","ts":%f,"request":{"remote_ip":"10.1.1.1","method":"GET","uri":"/u\\u001b\\u0085\\ud83d\\u00e9\\uFFFD"},"duration":1e-3,"size":1.5,"status":200}' % t); continue
    if k < 0.06: reql.append(b'{"level":"info","ts":%f,"request":{"remote_ip":"10.1.1.2","method":"GET","uri":"/n\\"q\\\\b\\/s\\b\\f\\r\\t"},"duration":2E-2,"size":10,"status":5e2}' % t); continue
    reql.append(req_line(t, m, p, st, dur, R.randint(0, 100000), R.random() < 0.8))
w('access.log', b'\n'.join(reql) + b'\n')
w('access-chunk.log', b'\n'.join(reql[:2000]) + b'\n' + reql[2000][:50])

# ---------------- journalctl -o json entries ----------------
def arr(bs): return list(bs)
msgs = [('s', 'plain line %d'), ('s', 'A2 Alpha <3> upper'), ('s', '{"level":"error","msg":"json error"}'),
  ('s', '{"level":40,"msg":"pino warn"}'), ('s', '{"severity": "CRITICAL"}'), ('s', '{"lvl":"verbose"}'), ('s', '{"level": 61}'),
  ('s', 'A6 WARN something'), ('s', 'NOTICE x'), ('s', 'xERROR no'), ('s', '1ERROR yes'), ('s', 'TypeError: A8 at start'),
  ('s', 'A7 TypeError: not at start'), ('s', '[error] bracket'), ('s', 'warning: lower'), ('s', 'warn] x'), ('s', 'Uncaught x'),
  ('s', 'Unhandled y'), ('s', 'H1 esc \u001b[2J\u001b[31mred\u001b]0;t\u0007 bell\r cr\n nl\t tab\b bs\f ff'), ('s', 'café \u0085 c1   \ud800'),
  ('s', 'quote " and \\ back'), ('s', 'DEBUG d'), ('s', 'TRACE t'), ('s', 'INFO i'), ('s', 'FATAL f'), ('s', 'PANIC p'),
  ('a', b'H2 c1 \xc2\x9b2J and \x9b raw and caf\xc3\xa9 \x1b \x7f \t'), ('a', b'\xe2\x82\xac euro \xf0\x9f\x98\x80 emoji \xed\xa0\x80 sur \xc0\xaf over \xf5\x80\x80\x80 big \xe0\x80\x80 ov3 \xc3'),
  ('a', b'\xe2\x82 short \xc3('), ('a', b'ERROR in bytes \x00 nul'), ('s', 'x' * 290 + ' ERROR late'), ('s', 'alpha beta Alpha BETA x41 Xe')]
units = [('tando-boom.service', None), ('systemd-journald@tando-boom.service', None), ('tando-boom-job-backup.service', None),
  ('tando-boom-2.service', None), ('init.scope', '1'), ('init.scope', '2'), (None, '1')]
ents = []
us = (T0 - 600) * 1000000
for i in range(3000):
    us += R.choice([1, 999, 1000, 123456, 2000000])
    kind, m = R.choice(msgs)
    e = {'__CURSOR': 's=%s;i=%x;b=%s;m=%x;t=%x;x=%s' % (hexs(32), i, hexs(32), i, us, hexs(16)), '__REALTIME_TIMESTAMP': str(us),
         '__MONOTONIC_TIMESTAMP': str(i)}
    if kind == 's':
        e['MESSAGE'] = m % i if '%d' in m else m
    else:
        e['MESSAGE'] = arr(m)
    if R.random() < 0.02: del e['MESSAGE']
    if R.random() < 0.85: e['PRIORITY'] = str(R.choice([0, 1, 2, 3, 4, 5, 6, 6, 6, 7]))
    u, pid = R.choice(units)
    if u: e['_SYSTEMD_UNIT'] = u
    e['_PID'] = pid or str(R.randint(100, 999))
    if pid == '1': e['UNIT'] = R.choice(['tando-boom.service', 'tando-other.service', 'tando-boom-job-backup.service'])
    s = json.dumps(e, separators=(',', ':'), ensure_ascii=True)
    ents.append(s.encode())
w('journal.json', b'\n'.join(ents) + b'\n')
print('ok', len(lines), len(reql), len(ents))
