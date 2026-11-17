// loadgen.js: open-loop HTTP load with a per-second timeline, for "operation under load" tests.
// node loadgen.js <url> <host|-> <rps> <max-inflight> <seconds> [ka|close] > timeline.tsv
// Each second: t (epoch s), sent, ok (2xx/3xx), status codes other than 2xx/3xx, errors by kind
// (ECONNREFUSED, ECONNRESET, timeout...), p50/p99/max latency ms of the requests finished in it,
// and "capped" (sends skipped because max-inflight requests were already open: the server is
// not keeping up). Requests time out after 10 s. A summary line "#END ..." at the end.
const http = require('http');
const [url, host, rps, maxIn, secs, mode] = process.argv.slice(2);
const u = new URL(url);
const ka = (mode || 'ka') === 'ka';
const agent = new http.Agent({ keepAlive: ka, maxSockets: Number(maxIn), maxFreeSockets: Number(maxIn) });
const R = Number(rps), MAX = Number(maxIn), END = Date.now() + Number(secs) * 1000;
let inflight = 0, cur = null, tot = { sent: 0, ok: 0, bad: 0, capped: 0 };
function bucket() {
  const s = Math.floor(Date.now() / 1000);
  if (!cur || cur.t !== s) { if (cur) flush(cur); cur = { t: s, sent: 0, ok: 0, codes: {}, errs: {}, lat: [], capped: 0 }; }
  return cur;
}
function flush(b) {
  b.lat.sort((a, c) => a - c);
  const q = p => b.lat.length ? b.lat[Math.min(b.lat.length - 1, Math.floor(p * b.lat.length))].toFixed(1) : '-';
  const kv = o => Object.entries(o).map(([k, v]) => k + ':' + v).join(',') || '-';
  process.stdout.write([b.t, b.sent, b.ok, kv(b.codes), kv(b.errs), q(0.5), q(0.99), b.lat.length ? b.lat[b.lat.length - 1].toFixed(0) : '-', b.capped, inflight].join('\t') + '\n');
}
function one() {
  const b = bucket();
  if (inflight >= MAX) { b.capped++; tot.capped++; return; }
  inflight++; b.sent++; tot.sent++;
  const t0 = process.hrtime.bigint();
  let done = false;
  const fin = (code, err) => {
    if (done) return; done = true; inflight--;
    const ms = Number(process.hrtime.bigint() - t0) / 1e6, bb = bucket();
    if (err) { bb.errs[err] = (bb.errs[err] || 0) + 1; tot.bad++; }
    else if (code >= 200 && code < 400) { bb.ok++; tot.ok++; bb.lat.push(ms); }
    else { bb.codes[code] = (bb.codes[code] || 0) + 1; tot.bad++; bb.lat.push(ms); }
  };
  const req = http.request({ host: u.hostname, port: u.port || 80, path: u.pathname + u.search, agent,
    headers: Object.assign(host && host !== '-' ? { Host: host } : {}, ka ? {} : { Connection: 'close' }) }, res => {
    res.on('data', () => {}); res.on('end', () => fin(res.statusCode)); res.on('error', e => fin(0, e.code || 'resErr'));
  });
  req.setTimeout(10000, () => { req.destroy(); fin(0, 'timeout'); });
  req.on('error', e => fin(0, e.code || 'err'));
  req.end();
}
const tick = 5; let carry = 0;
const iv = setInterval(() => {
  if (Date.now() >= END) { clearInterval(iv); const w = setInterval(() => { if (inflight === 0 || Date.now() > END + 11000) { clearInterval(w); flush(cur); process.stdout.write(`#END sent=${tot.sent} ok=${tot.ok} bad=${tot.bad} capped=${tot.capped}\n`); process.exit(0); } }, 100); return; }
  carry += R * tick / 1000; while (carry >= 1) { one(); carry--; }
}, tick);
