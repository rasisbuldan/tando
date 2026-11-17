// hello: zero-dependency test app for tando.
//   GET /        -> "hello v<VERSION> greeting=<GREETING>"
//   GET /health  -> 200, or 500 when UNHEALTHY_VERSION equals this version; "7@4100" means
//                   version 7 only when listening on port 4100 (passes pre-flight, fails after switch)
// CRASH_VERSION has the same form and makes the process exit at start (a crash loop).
// SLOW_START=<seconds> delays listening (gives tests a window during activation).
const http = require('http');
const fs = require('fs');
const version = fs.readFileSync(__dirname + '/VERSION', 'utf8').trim();
const port = Number(process.env.PORT || 3000);
const [uv, up] = (process.env.UNHEALTHY_VERSION || '').split('@');
const unhealthy = uv === version && (!up || Number(up) === port);
const [cv, cp] = (process.env.CRASH_VERSION || '').split('@');
if (cv === version && (!cp || Number(cp) === port)) {
  console.error(`hello v${version}: crashing on purpose`);
  process.exit(1);
}
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(unhealthy ? 500 : 200, { 'content-type': 'text/plain' });
    return res.end(unhealthy ? 'unhealthy\n' : 'ok\n');
  }
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end(`hello v${version} greeting=${process.env.GREETING || ''}\n`);
});
setTimeout(() => server.listen(port, '127.0.0.1', () => console.log(`hello v${version} on ${port}`)),
  Number(process.env.SLOW_START || 0) * 1000);
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
