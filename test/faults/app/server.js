// fault app for tando fault-injection scenarios. Behaviour from the shipped BEHAVIOR file:
// comma-separated words; "word@live" applies only on the live port (< 4200; pre-flight is +100).
//   ok | exit | needenv (exits unless NEED is set) | hang | wrongport | crash20 | oom | nosigterm | forkchild | logflood | slow:N | unhealthy
const http = require('http');
const fs = require('fs');
const cp = require('child_process');
const v = fs.readFileSync(__dirname + '/VERSION', 'utf8').trim();
let words = [];
try { words = fs.readFileSync(__dirname + '/BEHAVIOR', 'utf8').trim().split(','); } catch (e) {}
const port = Number(process.env.PORT || 3000);
const live = port < 4200;
const has = (w) => words.some((x) => x === w || (x === w + "@live" && live) || (x === w + "@pre" && !live) ||
  x.startsWith(w + ":") || (x.startsWith(w + "@live:") && live) || (x.startsWith(w + "@pre:") && !live));
const arg = (w) => { const x = words.find((y) => y.startsWith(w + ":") || (y.startsWith(w + "@live:") && live) || (y.startsWith(w + "@pre:") && !live));
  return x ? Number(x.split(":")[1]) : 0; };

if (process.argv[2] === 'child') {           // forkchild: keep the inherited server handle alive
  process.on('SIGTERM', () => {});
  process.on('message', (m, h) => { if (m === 'server') h.on('connection', (s) => s.end('HTTP/1.1 200 OK\r\ncontent-length: 6\r\n\r\nchild\n')); });
  setInterval(() => {}, 1e6);
  return;
}
if (has('exit')) { console.error('exit on purpose'); process.exit(1); }
if (has('needenv') && !process.env.NEED) { console.error('Error: NEED is not set'); process.exit(1); }
if (has('nosigterm')) process.on('SIGTERM', () => console.log('ignoring SIGTERM'));
else process.on('SIGTERM', () => process.exit(0));
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    const bad = has('unhealthy');
    res.writeHead(bad ? 500 : 200); return res.end(bad ? 'unhealthy\n' : 'ok\n');
  }
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end(`v${v}\n`);
});
if (has('hang')) { setInterval(() => {}, 1e6); }
else {
  const p = has('wrongport') ? port + 1 : port;
  setTimeout(() => server.listen(p, '127.0.0.1', () => {
    console.log(`fault app v${v} on ${p} (${words.join(',')})`);
    if (has('forkchild')) {
      const c = cp.fork(__filename, ['child'], { detached: true, stdio: 'ignore' });
      c.send('server', server); c.unref();
    }
  }), arg('slow') * 1000);
}
if (has('crash20')) setTimeout(() => { console.error('crash after 20 s'); process.exit(1); }, 20000);
if (has('oom')) { const hog = []; setTimeout(() => setInterval(() => hog.push(Buffer.alloc(8 << 20, 1)), 100), 5000); }
if (has('writer')) { const p = (process.env.TANDO_DATA_DIR || '.') + '/log.txt'; let n = 0; setInterval(() => fs.appendFileSync(p, 'line ' + (n++) + '\n'), 20); }
if (has('logflood')) { const line = 'x'.repeat(1000); setInterval(() => { for (let i = 0; i < 2000; i++) console.log(line); }, 10); }
