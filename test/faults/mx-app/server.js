// The fault matrix's app (test/e2e-matrix.sh). One file for every version: what differs ships
// beside it. VERSION: the version it answers with. HEALTH: its own health path (versions
// alternate between two, so a health path left from the other version answers 404). BEHAVIOR:
// "unhealthy@live" (500 on its health path on the live port only: fails after the switch),
// "exit@pre" (exits on the pre-flight port: refused before the switch). Env: MXVAL is echoed
// on /, MX_BAD=1 makes it unhealthy on the live port (an env change that must be reverted).
// GET / answers "v<VERSION> env=<MXVAL>". Live ports are 4100-4199, pre-flight ones +100.
const http = require('http');
const fs = require('fs');
const rd = (f, d) => { try { return fs.readFileSync(__dirname + '/' + f, 'utf8').trim(); } catch (e) { return d; } };
const v = rd('VERSION', '0'), hp = rd('HEALTH', '/health'), beh = rd('BEHAVIOR', '');
const port = Number(process.env.PORT || 3000), live = port < 4200;
if (beh.includes('exit@pre') && !live) { console.error('exit on the pre-flight port, on purpose'); process.exit(1); }
const bad = (beh.includes('unhealthy@live') && live) || (process.env.MX_BAD === '1' && live);
process.on('SIGTERM', () => process.exit(0));
http.createServer((q, s) => {
  const u = q.url.split('?')[0];
  if (u === hp) { s.writeHead(bad ? 500 : 200); return s.end(bad ? 'unhealthy\n' : 'ok\n'); }
  if (u === '/') { s.writeHead(200, { 'content-type': 'text/plain' }); return s.end(`v${v} env=${process.env.MXVAL || '-'}\n`); }
  s.writeHead(404); s.end('not here\n');
}).listen(port, '127.0.0.1', () => console.log(`mx v${v} on ${port} health ${hp}`));
