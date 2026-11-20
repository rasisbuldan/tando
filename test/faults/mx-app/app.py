# The fault matrix's app for recipe = python: the same answers as server.js (see there).
import os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
here = os.path.dirname(os.path.abspath(__file__))
def rd(f, d):
    try:
        return open(os.path.join(here, f)).read().strip()
    except OSError:
        return d
v, hp, beh = rd('VERSION', '0'), rd('HEALTH', '/health'), rd('BEHAVIOR', '')
port = int(os.environ.get('PORT', '3000')); live = port < 4200
if 'exit@pre' in beh and not live:
    sys.exit('exit on the pre-flight port, on purpose')
bad = ('unhealthy@live' in beh and live) or (os.environ.get('MX_BAD') == '1' and live)
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        u = self.path.split('?')[0]
        if u == hp:
            code, body = (500, 'unhealthy\n') if bad else (200, 'ok\n')
        elif u == '/':
            code, body = 200, 'v%s env=%s\n' % (v, os.environ.get('MXVAL', '-'))
        else:
            code, body = 404, 'not here\n'
        b = body.encode()
        self.send_response(code); self.send_header('content-length', str(len(b))); self.end_headers(); self.wfile.write(b)
HTTPServer(('127.0.0.1', port), H).serve_forever()
