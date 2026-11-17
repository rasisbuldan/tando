// logflood: zero-dependency test app for tando logging (test/e2e-logs.sh).
//   GET /health            -> 200 "ok"
//   GET /status/<code>     -> answers with that HTTP status
//   GET /sleep/<ms>        -> waits <ms> milliseconds, then 200
//   GET /emit?line=<text>&stream=out|err  -> writes <text> (URL-decoded) as one log line
//   GET /flood/<n>?size=<bytes>           -> writes n lines of about <bytes> each, as fast as it can
// It never logs request headers or query strings by itself.
const http = require('http');
const port = Number(process.env.PORT || 3000);

function flood(n, size, done) {
  const pad = 'x'.repeat(Math.max(0, size - 40));
  let i = 0;
  (function chunk() {
    let buf = '';
    for (let k = 0; k < 500 && i < n; k++, i++) buf += `flood ${i} ${pad}\n`;
    if (!process.stdout.write(buf)) process.stdout.once('drain', next); else next();
    function next() { if (i < n) setImmediate(chunk); else done(); }
  })();
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  const parts = u.pathname.split('/');
  const end = (code, body) => { res.writeHead(code, { 'content-type': 'text/plain' }); res.end(body + '\n'); };
  if (u.pathname === '/health') return end(200, 'ok');
  if (parts[1] === 'status') return end(Number(parts[2]) || 500, 'status ' + parts[2]);
  if (parts[1] === 'sleep') return setTimeout(() => end(200, 'slept ' + parts[2]), Number(parts[2]) || 0);
  if (u.pathname === '/emit') {
    const line = u.searchParams.get('line') || '';
    (u.searchParams.get('stream') === 'err' ? process.stderr : process.stdout).write(line + '\n');
    return end(200, 'emitted');
  }
  if (parts[1] === 'flood') {
    return flood(Number(parts[2]) || 1000, Number(u.searchParams.get('size')) || 100, () => end(200, 'flooded'));
  }
  end(200, 'logflood');
});
server.listen(port, '127.0.0.1', () => console.log(`logflood on ${port}`));
// SIGTERM (a restart or deploy): stop accepting, answer the requests in flight with
// "Connection: close" and close idle keep-alive connections, so the process ends in moments even
// while Caddy keeps its pooled connections busy (server.close() alone waits for every one of them)
let closing = false;
server.prependListener('request', (req, res) => { if (closing) res.setHeader('connection', 'close'); });
process.on('SIGTERM', () => {
  closing = true;
  server.close(() => process.exit(0));
  server.closeIdleConnections();
  setInterval(() => server.closeIdleConnections(), 100).unref();
});
