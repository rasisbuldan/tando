// notes: a small app with PostgreSQL (DATABASE_URL from tando) and a file in data/.
//   GET  /health        -> 200 when the database answers
//   GET  /              -> "notes v<VERSION> db=<rows> file=<lines>"
//   POST /notes?text=x  -> stores x in the database and appends it to data/notes.log
const http = require('http');
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');

const version = fs.readFileSync(path.join(__dirname, 'VERSION'), 'utf8').trim();
const port = Number(process.env.PORT || 3000);
const log = path.join(process.env.TANDO_DATA_DIR || path.join(__dirname, 'data'), 'notes.log');
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 3 });

const lines = () => {
  try { return fs.readFileSync(log, 'utf8').split('\n').filter(Boolean).length; } catch { return 0; }
};

async function handle(req, res) {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/health') {
    await pool.query('SELECT 1');
    return res.end('ok\n');
  }
  if (url.pathname === '/notes' && req.method === 'POST') {
    const text = url.searchParams.get('text') || '';
    await pool.query('INSERT INTO notes (text) VALUES ($1)', [text]);
    fs.appendFileSync(log, text + '\n');
    return res.end('stored\n');
  }
  const { rows } = await pool.query('SELECT count(*)::int AS n FROM notes');
  res.end(`notes v${version} db=${rows[0].n} file=${lines()}\n`);
}

pool.query('CREATE TABLE IF NOT EXISTS notes (id serial PRIMARY KEY, text text NOT NULL)')
  .then(() => {
    const server = http.createServer((req, res) => handle(req, res).catch((e) => {
      res.statusCode = 500;
      res.end(`error: ${e.message}\n`);
    }));
    server.listen(port, '127.0.0.1', () => console.log(`notes v${version} on ${port}`));
    process.on('SIGTERM', () => server.close(() => pool.end().then(() => process.exit(0))));
  })
  .catch((e) => { console.error(e.message); process.exit(1); });
