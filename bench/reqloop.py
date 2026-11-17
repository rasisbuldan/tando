#!/usr/bin/env python3
"""Request loop: about 10 requests/s, one new TCP connection each, 5 s timeout.
usage: reqloop.py URL OUTFILE [HOST_HEADER]   (stop with SIGTERM/SIGINT)
Writes one line per request: start_ms status latency_ms (status 000 = connection error/timeout)."""
import sys, time, signal, http.client, urllib.parse
url, out = sys.argv[1], sys.argv[2]
host = sys.argv[3] if len(sys.argv) > 3 else None
u = urllib.parse.urlparse(url)
stop = False
def handler(*_):
    global stop; stop = True
signal.signal(signal.SIGTERM, handler); signal.signal(signal.SIGINT, handler)
f = open(out, 'w', buffering=1)
nxt = time.time()
while not stop:
    t0 = time.time()
    code = '000'
    try:
        c = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=5)
        c.request('GET', u.path or '/', headers={'Host': host} if host else {})
        r = c.getresponse(); r.read(); code = str(r.status); c.close()
    except Exception:
        pass
    t1 = time.time()
    f.write(f"{int(t0*1000)} {code} {(t1-t0)*1000:.1f}\n")
    nxt += 0.1
    time.sleep(max(0, nxt - time.time()))
    if nxt < time.time() - 1: nxt = time.time()
