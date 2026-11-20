// tando studio: the page (srv/studio/ui). No framework, no external request, no inline script.
// Everything from the database reaches the page through textContent only: an app's tables can
// hold markup (the CSP's Trusted Types make an HTML sink fail in Chromium too).
'use strict';
const $ = id => document.getElementById(id);
const el = (t, cls, txt) => { const e = document.createElement(t); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; };
const fmt = n => Number(n).toLocaleString('en-US');
const NUM = new Set([20, 21, 23, 26, 700, 701, 1700]), JSONT = new Set([114, 3802]);
const S = { token: '', info: null, key: null, ended: false, busy: false, qid: 0, running: '', t: null, res: [], cur: 0, hist: [] };
const LS = { get(k) { try { return localStorage.getItem(k); } catch { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch { } }, del(k) { try { localStorage.removeItem(k); } catch { } } };

// ---- talking to the studio --------------------------------------------------------------------
class Gone extends Error { }
async function api(path, body) {
  if (S.ended) throw new Gone();
  let r;
  try {
    r = await fetch(path, { method: body ? 'POST' : 'GET', headers: Object.assign({ Authorization: 'Bearer ' + S.token }, body ? { 'Content-Type': 'application/json' } : {}), body: body ? JSON.stringify(body) : undefined, cache: 'no-store' });
  } catch (e) { ended(''); throw new Gone(); }
  if (r.status === 401) { ended('The server no longer knows this page (the session was stopped or restarted).'); throw new Gone(); }
  let j;
  try { j = await r.json(); } catch { j = {}; }
  if (!r.ok) throw new Error((j.error && j.error.message) || ('HTTP ' + r.status));
  return j;
}
function ended(why) {
  if (S.ended) return;
  S.ended = true;
  saveDraft();
  $('end-why').textContent = (why || 'The connection to the studio is gone: it was stopped (Ctrl-C, Stop, idle time) or the computer slept.') + ' (Another app: tando db studio <app>.)';
  $('end-cmd').textContent = 'tando db studio' + (S.info ? ' ' + S.info.app : '');
  if (S.info) $('end-title').textContent = 'The studio of ' + S.info.app + ' ended';
  $('ended').hidden = false;
}

// ---- encrypted history and draft (AES-GCM, key from the server: a later local page on this
// port cannot read them) -------------------------------------------------------------------------
const b64 = { enc: b => btoa(String.fromCharCode(...new Uint8Array(b))), dec: s => Uint8Array.from(atob(s), c => c.charCodeAt(0)) };
async function seal(obj) {
  if (!S.key) return null;
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, S.key, new TextEncoder().encode(JSON.stringify(obj)));
  return b64.enc(iv) + '.' + b64.enc(ct);
}
async function unseal(s) {
  if (!S.key || !s) return null;
  try {
    const [iv, ct] = s.split('.');
    return JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: b64.dec(iv) }, S.key, b64.dec(ct))));
  } catch { return null; }
}
const lsKey = s => 'tando.studio.' + (S.info ? S.info.app : '') + s;
let draftT = 0;
function saveDraft() { clearTimeout(draftT); seal({ sql: $('ed').value }).then(v => v && LS.set(lsKey('.draft'), v)); }
async function addHist(sql, ok, ms) {
  S.hist = S.hist.filter(h => h.sql !== sql);
  S.hist.unshift({ sql: sql.slice(0, 20000), t: Date.now(), ok, ms });
  S.hist.length = Math.min(S.hist.length, 100);
  const v = await seal(S.hist); if (v) LS.set(lsKey('.history'), v);
  if (!$('hist').hidden) showHist();
}
function showHist() {
  const l = $('h-list'); l.replaceChildren();
  if (!S.hist.length) l.append(el('li', 'dim', 'Nothing yet. Queries you run are kept here, encrypted.'));
  for (const h of S.hist) {
    const li = el('li'), meta = el('div', 'small dim');
    meta.append(new Date(h.t).toLocaleString(), ' · ', h.ok ? h.ms + ' ms' : '');
    if (!h.ok) meta.append(el('span', 'bad', 'error'));
    li.append(el('pre', null, h.sql), meta);
    li.onclick = () => { setEd(h.sql); $('hist').hidden = true; $('ed').focus(); };
    l.append(li);
  }
  $('hist').hidden = false;
}

// ---- cells -----------------------------------------------------------------------------------
function cellText(v, oid) {
  if (oid === 16) return v === 't' ? 'true' : v === 'f' ? 'false' : v;
  if (oid === 17 && v.length > 34) return v.slice(0, 34) + '…';
  return v.length > 200 ? v.slice(0, 200) + '…' : v;
}
function humanBytes(n) {
  if (n < 1024) return n + ' B';
  const u = ['KB', 'MB', 'GB', 'TB']; let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < 3);
  return (n < 10 ? n.toFixed(1) : Math.round(n)) + ' ' + u[i];
}
function approx(n) {
  if (n < 0) return '?';
  if (n < 1000) return String(n);
  const u = ['k', 'M', 'B']; let i = -1;
  do { n /= 1000; i++; } while (n >= 1000 && i < 2);
  return '~' + (n < 10 ? n.toFixed(1) : Math.round(n)) + u[i];
}
// grid: a table of cols ({name, oid, type}) and rows (strings or null); cut: "r,c" -> full length
// (0 unknown); sort: optional {col, desc, on(col)}; base: the number of the first row
function grid(tb, cols, rows, cut, sort, base, from) {
  if (!from) {
    tb.replaceChildren();
    const hr = el('tr'), th0 = el('th', 'rn', '#');
    hr.append(th0);
    cols.forEach(c => {
      const th = el('th', sort ? 's' : null, c.name);
      if (sort && sort.col === c.name) th.append(sort.desc ? ' ↓' : ' ↑');
      if (c.type) th.append(el('small', null, c.type));
      if (sort) th.onclick = () => sort.on(c.name);
      hr.append(th);
    });
    const th = el('thead'); th.append(hr); tb.append(th, el('tbody'));
  }
  const body = tb.tBodies[0], frag = document.createDocumentFragment(), end = Math.min(rows.length, (from || 0) + 1000);
  for (let r = from || 0; r < end; r++) {
    const tr = el('tr');
    tr.append(el('td', 'rn', String(base + r + 1)));
    rows[r].forEach((v, c) => {
      const oid = cols[c] ? cols[c].oid : 0, td = el('td');
      if (v === null) td.append(el('span', 'null', 'NULL'));
      else if (v === '') td.append(el('span', 'emp', "''"));
      else { td.textContent = cellText(v, oid); if (NUM.has(oid)) td.className = 'n'; }
      const k = r + ',' + c;
      if (cut.has(k)) td.classList.add('cut');
      td.onclick = () => drawer(cols[c], v, cut.has(k) ? cut.get(k) : -1);
      tr.append(td);
    });
    frag.append(tr);
  }
  body.append(frag);
  return end;
}
function drawer(col, v, full) {
  $('d-title').textContent = col ? col.name + (col.type ? '  ' + col.type : '') : '';
  let txt = v === null ? 'NULL' : v, note = '';
  if (v !== null && JSONT.has(col.oid) && full < 0) { try { txt = JSON.stringify(JSON.parse(v), null, 2); } catch { } }
  if (v !== null && col.oid === 17) {
    const bytes = full > 0 ? full : (v.length - 2) / 2;
    note = 'bytea, ' + humanBytes(bytes) + '; the first 64 bytes:';
    txt = (v.slice(2, 130).match(/../g) || []).join(' ');
  } else if (full >= 0) note = 'Cut: showing the first ' + humanBytes(new TextEncoder().encode(v).length) + (full > 0 ? ' of ' + humanBytes(full) : '') + '. The whole value: SELECT it in tando db psql.';
  $('d-note').textContent = note; $('d-note').hidden = !note;
  $('d-val').textContent = txt;
  $('d-val').classList.toggle('null', v === null);
  S.dval = v === null ? '' : txt;
  $('hist').hidden = true; $('drawer').hidden = false;
}

// ---- tables ----------------------------------------------------------------------------------
const KIND = { r: 'T', p: 'P', v: 'V', m: 'M', f: 'F' }, KINDW = { r: 'table', p: 'partitioned table', v: 'view', m: 'materialized view', f: 'foreign table' };
let tables = [];
async function loadTables() {
  try {
    const j = await api('/api/tables' + ($('sys').checked ? '?system=1' : ''));
    tables = j.tables;
    $('sidenote').textContent = j.more ? 'Only the first 2,000 are listed: filter to find others.' : tables.length ? '' : 'No tables yet.';
    drawTree();
  } catch (e) { if (!(e instanceof Gone)) $('sidenote').textContent = 'Could not list the tables: ' + e.message; }
}
function drawTree() {
  const f = $('filter').value.trim().toLowerCase(), tree = $('tree');
  tree.replaceChildren();
  let sch = null, n = 0;
  for (const t of tables) {
    if (f && !(t.schema + '.' + t.name).toLowerCase().includes(f)) continue;
    if (t.schema !== sch) { sch = t.schema; tree.append(el('div', 'sch', sch)); }
    const b = el('button', 'it');
    b.title = KINDW[t.kind] + ' ' + t.schema + '.' + t.name + (t.comment ? '\n' + t.comment : '') + (t.select ? '' : '\n(no SELECT privilege)');
    b.append(el('span', 'k', KIND[t.kind] || '?'), el('span', 'nm', t.name), el('span', 'ct', (t.kind === 'v' || t.kind === 'f' ? '' : approx(t.est)) + (t.bytes ? ' · ' + humanBytes(t.bytes) : '')));
    if (S.t && S.t.schema === t.schema && S.t.name === t.name) b.setAttribute('aria-current', 'true');
    b.onclick = () => openTable(t);
    tree.append(b); n++;
  }
  if (!n && tables.length) tree.append(el('p', 'dim small pad', 'No table matches.'));
}
function openTable(t) {
  S.t = { schema: t.schema, name: t.name, kind: t.kind, est: t.est, offset: 0, sort: '', desc: false, cols: null };
  tab('tables');
  $('t-empty').hidden = true; $('t-head').hidden = false;
  $('t-name').textContent = (t.schema === 'public' ? '' : t.schema + '.') + t.name;
  $('t-meta').textContent = KINDW[t.kind] + (t.kind === 'v' || t.kind === 'f' ? '' : ' · ' + (t.est < 0 ? 'rows not counted yet' : approx(t.est) + ' rows')) + (t.bytes ? ' · ' + humanBytes(t.bytes) : '');
  drawTree();
  sub('rows');
}
function sub(w) {
  $('s-rows').setAttribute('aria-selected', w === 'rows'); $('s-struct').setAttribute('aria-selected', w !== 'rows');
  $('p-rows').hidden = w !== 'rows'; $('p-struct').hidden = w === 'rows';
  w === 'rows' ? loadRows() : loadStruct();
}
async function loadRows() {
  const t = S.t; if (!t) return;
  const limit = +$('psize').value;
  $('pg-note').textContent = 'loading…';
  try {
    const j = await api('/api/rows', { schema: t.schema, name: t.name, offset: t.offset, limit, sort: t.sort, desc: t.desc });
    if (S.t !== t) return;
    if (j.error) { $('pg-note').textContent = j.error.message; $('grid').replaceChildren(); return; }
    const r = j.result, cut = new Map(r.trunc.map(x => [x[0] + ',' + x[1], x[2]]));
    t.cols = r.columns;
    grid($('grid'), r.columns, r.rows, cut, { col: t.sort, desc: t.desc, on: c => { if (t.sort !== c) { t.sort = c; t.desc = false; } else if (!t.desc) t.desc = true; else t.sort = ''; t.offset = 0; loadRows(); } }, t.offset);
    const n = r.rows.length;
    $('pg-info').textContent = n ? fmt(t.offset + 1) + '–' + fmt(t.offset + n) + (t.est > 0 ? ' of ~' + fmt(t.est) : '') : t.offset ? 'no rows past ' + fmt(t.offset) : 'no rows';
    $('pg-prev').disabled = $('pg-first').disabled = !t.offset;
    $('pg-next').disabled = !j.has_more;
    $('pg-note').textContent = r.reason === 'bytes' ? 'page cut: over 8 MB of data' : (!t.sort && t.kind !== 'r' && t.kind !== 'm' && t.kind !== 'p' ? 'a view has no key: pages may overlap' : '');
  } catch (e) { if (!(e instanceof Gone)) $('pg-note').textContent = e.message; }
}
async function loadStruct() {
  const t = S.t, p = $('p-struct');
  try {
    const j = await api('/api/table?schema=' + encodeURIComponent(t.schema) + '&name=' + encodeURIComponent(t.name));
    if (S.t !== t) return;
    t.cols = j.columns;
    p.replaceChildren();
    if (j.comment) p.append(el('p', 'dim', j.comment));
    p.append(el('h3', null, 'Columns'));
    const rows = j.columns.map(c => [c.name, c.type, c.nullable ? '' : 'not null', c.default || (c.identity ? 'identity (' + (c.identity === 'a' ? 'always' : 'by default') + ')' : '') || (c.generated ? 'generated' : ''), c.pk ? 'PK ' + c.pk : '']);
    const g1 = el('table', 'grid'); p.append(g1);
    grid(g1, ['name', 'type', 'null', 'default', 'key'].map(n => ({ name: n })), rows.map(r => r.map(x => x || ' ')), new Map(), null, 0);
    p.append(el('h3', null, 'Indexes'));
    if (!j.indexes.length) p.append(el('p', 'dim', 'None.'));
    else { const g2 = el('table', 'grid'); p.append(g2); grid(g2, [{ name: 'name' }, { name: 'definition' }], j.indexes.map(i => [i.name, i.def]), new Map(), null, 0); }
  } catch (e) { if (!(e instanceof Gone)) { p.replaceChildren(el('p', 'err', e.message)); } }
}
const qi = s => /^[a-z_][a-z0-9_]*$/.test(s) ? s : '"' + s.replace(/"/g, '""') + '"';
function openInSQL() {
  const t = S.t; if (!t) return;
  const pk = (t.cols || []).filter(c => c.pk).sort((a, b) => a.pk - b.pk).map(c => qi(c.name));
  setEd('SELECT *\nFROM ' + (t.schema === 'public' ? '' : qi(t.schema) + '.') + qi(t.name) + '\n-- WHERE ...\n' + (pk.length ? 'ORDER BY ' + pk.join(', ') + '\n' : '') + 'LIMIT 100;\n');
  tab('sql'); $('ed').focus();
}

// ---- the editor ------------------------------------------------------------------------------
// split: the statements of the text as [start, end) in UTF-16 indexes, as srv/studio/sqlsplit
// splits them ('...', E'...', "...", $tag$...$tag$, -- and nested /* */)
function split(s) {
  const out = []; let st = 0, i = 0, has = false;
  const push = e => { if (has) out.push([st, e]); has = false; };
  while (i < s.length) {
    const c = s[i], d = s[i + 1];
    if (c === ';') { push(i); st = ++i; continue; }
    if (c === '-' && d === '-') { while (i < s.length && s[i] !== '\n') i++; continue; }
    if (c === '/' && d === '*') { let n = 0; while (i < s.length) { if (s[i] === '/' && s[i + 1] === '*') { n++; i += 2; } else if (s[i] === '*' && s[i + 1] === '/') { i += 2; if (!--n) break; } else i++; } continue; }
    if (/\s/.test(c)) { i++; continue; }
    has = true;
    if (c === "'" || c === '"') {
      const esc = c === "'" && /[eE]/.test(s[i - 1] || '') && !/[\w$]/.test(s[i - 2] || '');
      i++;
      while (i < s.length) { if (esc && s[i] === '\\') i += 2; else if (s[i] === c) { if (s[i + 1] === c) i += 2; else { i++; break; } } else i++; }
    } else if (c === '$' && !/[\w$]/.test(s[i - 1] || '')) {
      const m = /^\$([A-Za-z_\u0080-\uffff][\w\u0080-\uffff]*)?\$/.exec(s.slice(i, i + 64));
      if (m) { const j = s.indexOf(m[0], i + m[0].length); i = j < 0 ? s.length : j + m[0].length; } else i++;
    } else i++;
  }
  push(s.length);
  return out.map(([a, b]) => { while (/\s/.test(s[a] || '')) a++; while (b > a && /\s/.test(s[b - 1])) b--; return [a, b]; }).filter(([a, b]) => b > a);
}
function setEd(v) { const e = $('ed'); e.value = v; e.setSelectionRange(v.length, v.length); pos(); saveDraft(); }
function pos() {
  const e = $('ed'), b = e.value.slice(0, e.selectionStart), l = b.split('\n');
  $('pos').textContent = l.length + ':' + (l[l.length - 1].length + 1) + (e.selectionEnd > e.selectionStart ? ' (' + (e.selectionEnd - e.selectionStart) + ' selected)' : '');
}
// what to run: the selection, else the statement under (or just before) the cursor, else all
function pick(all) {
  const e = $('ed'), v = e.value;
  if (all) return [0, v.length];
  if (e.selectionEnd > e.selectionStart) return [e.selectionStart, e.selectionEnd];
  const p = e.selectionStart, ss = split(v);
  let best = null;
  for (const s of ss) { if (s[0] <= p) best = s; if (p >= s[0] && p <= s[1] + 1) { best = s; break; } }
  return best || ss[0] || [0, v.length];
}
// cp2u: a 1-based code-point position in s as a UTF-16 index (PostgreSQL counts characters)
function cp2u(s, cp) { let i = 0, n = 1; while (n < cp && i < s.length) { i += s.codePointAt(i) > 0xffff ? 2 : 1; n++; } return i; }
async function run(all) {
  if (S.busy || S.ended) return;
  const [a, b] = pick(all), e = $('ed'), sql = e.value.slice(a, b);
  if (!sql.trim()) { status('Nothing to run.'); return; }
  const id = 'q' + (++S.qid); S.running = id; busy(true);
  status('Running ' + (split(sql).length || 1) + ' statement(s)…  ⌘/Ctrl+. cancels', true);
  $('qerr').hidden = true;
  let j;
  try { j = await api('/api/query', { id, sql, max_rows: +$('maxrows').value }); }
  catch (x) { busy(false); if (!(x instanceof Gone)) status(x.message); return; }
  finally { S.running = ''; }
  busy(false);
  const types = j.types || {};
  S.res = j.results.map(r => (r.columns.forEach(c => { if (!c.type && types[c.oid]) c.type = types[c.oid]; }), r));
  let rows = 0; S.res.forEach(r => rows += r.rows.length);
  const tr = S.res.find(r => r.truncated);
  status(fmt(S.res.length) + (S.res.length === 1 ? ' statement' : ' statements') + ' · ' + fmt(j.ms) + ' ms · ' + fmt(rows) + (rows === 1 ? ' row' : ' rows') + (tr ? (tr.reason === 'bytes' ? ' (cut: the 8 MB answer limit)' : ' (stopped at ' + fmt(tr.rows.length) + ')') : ''));
  if (j.error) showErr(j.error, sql, a);
  $('notices').replaceChildren(...(j.notices || []).map(n => el('li', null, n.severity + ': ' + n.message)));
  tabsRes(S.res.length - 1);
  addHist(sql, !j.error, j.ms);
}
function showErr(x, sql, base) {
  const q = $('qerr'); q.replaceChildren();
  q.append(el('b', null, (x.sqlstate ? x.sqlstate + ' ' : '') + x.message));
  if (x.detail) q.append('\n', 'Detail: ' + x.detail);
  if (x.hint) q.append('\n', 'Hint: ' + x.hint);
  if (x.position > 0) {
    const e = $('ed'), u = base + cp2u(sql, x.position), v = e.value;
    let z = u; while (z < v.length && /[\w$."]/.test(v[z])) z++;
    const ln = v.slice(0, u).split('\n');
    q.append('\n', 'at line ' + ln.length + ', column ' + (ln[ln.length - 1].length + 1));
    e.focus(); e.setSelectionRange(u, Math.max(z, u + 1)); pos();
  }
  q.hidden = false;
}
function tabsRes(sel) {
  const t = $('rtabs'); t.replaceChildren();
  if (S.res.length > 1 || (S.res.length === 1 && S.res[0].columns.length)) S.res.forEach((r, i) => {
    const b = el('button', null, (S.res.length > 1 ? (i + 1) + ': ' : '') + (r.command || 'result'));
    b.setAttribute('aria-selected', i === sel); b.onclick = () => tabsRes(i); t.append(b);
  });
  if (S.res.length) {
    const csv = el('button', null, 'CSV'); csv.title = 'Download this result (cells that start with = + - @ are guarded for spreadsheets; Shift-click: raw)';
    csv.onclick = ev => download(S.res[S.cur], ev.shiftKey); t.append(el('span', 'grow'), csv);
  }
  S.cur = sel; showRes();
}
function showRes() {
  const r = S.res[S.cur], g = $('rgrid'), m = $('rmore');
  m.hidden = true;
  if (!r || !r.columns.length) { g.replaceChildren(); return; }
  const cut = new Map(r.trunc.map(x => [x[0] + ',' + x[1], x[2]]));
  let shown = grid(g, r.columns, r.rows, cut, null, 0);
  const more = () => {
    if (shown >= r.rows.length) { m.hidden = true; return; }
    m.replaceChildren(el('span', 'dim', 'Showing ' + fmt(shown) + ' of ' + fmt(r.rows.length) + ' rows. '));
    const b = el('button', null, 'Show 1,000 more'); b.onclick = () => { shown = grid(g, r.columns, r.rows, cut, null, 0, shown); more(); };
    m.append(b); m.hidden = false;
  };
  more();
}
function download(r, raw) {
  if (!r || !r.columns.length) return;
  const q = v => {
    if (v === null) return '';
    if (!raw && /^[=+\-@\t\r]/.test(v)) v = "'" + v;
    return /[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
  };
  const lines = [r.columns.map(c => q(c.name)).join(',')].concat(r.rows.map(row => row.map(q).join(',')));
  const name = ((S.info ? S.info.app : 'studio') + '-' + (r.command || 'result')).replace(/[^A-Za-z0-9._-]+/g, '_').slice(0, 60) + (r.truncated ? '-truncated' : '') + '.csv';
  const a = el('a'); a.href = URL.createObjectURL(new Blob([lines.join('\r\n') + '\r\n'], { type: 'text/csv' })); a.download = name;
  document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 5000);
}
async function cancel() { if (S.running) { status('Cancelling…', true); try { await api('/api/cancel', { id: S.running }); } catch { } } }
function busy(b) { S.busy = b; $('b-run').disabled = $('b-all').disabled = b; $('b-cancel').disabled = !b; }
function status(t, spin) { const s = $('status'); s.textContent = t; s.classList.toggle('busy', !!spin); }

// ---- frame -----------------------------------------------------------------------------------
function tab(w) {
  $('t-tables').setAttribute('aria-selected', w === 'tables'); $('t-sql').setAttribute('aria-selected', w === 'sql');
  $('v-tables').hidden = w !== 'tables'; $('v-sql').hidden = w === 'tables';
  if (w === 'sql') $('ed').focus();
}
const THEMES = ['', 'dark', 'light'];
function theme(step) {
  let t = LS.get('tando.studio.theme') || '';
  if (step) { t = THEMES[(THEMES.indexOf(t) + 1) % 3]; LS.set('tando.studio.theme', t); }
  if (t) document.documentElement.dataset.theme = t; else delete document.documentElement.dataset.theme;
  $('b-theme').title = 'Theme: ' + (t || 'follows the system') + ' (click to change)';
}
function wire() {
  $('t-tables').onclick = () => tab('tables'); $('t-sql').onclick = () => tab('sql');
  $('s-rows').onclick = () => sub('rows'); $('s-struct').onclick = () => sub('struct');
  $('b-insql').onclick = openInSQL;
  $('filter').oninput = drawTree;
  $('sys').onchange = loadTables;
  $('psize').onchange = () => { if (S.t) { S.t.offset = 0; loadRows(); } };
  const page = d => () => { const t = S.t; if (!t) return; const n = +$('psize').value; t.offset = d === 0 ? 0 : Math.max(0, t.offset + d * n); loadRows(); };
  $('pg-first').onclick = page(0); $('pg-prev').onclick = page(-1); $('pg-next').onclick = page(1);
  $('b-run').onclick = () => run(false); $('b-all').onclick = () => run(true); $('b-cancel').onclick = cancel;
  $('b-hist').onclick = () => $('hist').hidden ? showHist() : ($('hist').hidden = true);
  $('h-close').onclick = () => $('hist').hidden = true;
  $('h-clear').onclick = () => { S.hist = []; LS.del(lsKey('.history')); showHist(); };
  $('d-close').onclick = () => $('drawer').hidden = true;
  $('d-copy').onclick = () => navigator.clipboard.writeText(S.dval).then(() => { $('d-copy').textContent = 'Copied'; setTimeout(() => $('d-copy').textContent = 'Copy', 1200); });
  $('b-theme').onclick = () => theme(1);
  $('b-keys').onclick = () => $('keys').hidden = false;
  $('keys').onclick = () => $('keys').hidden = true;
  $('ed').dataset.gramm = 'false';   // (writing-assistant extensions stay out of the SQL)
  $('b-stop').onclick = async () => { saveDraft(); try { await api('/api/end', {}); } catch { } ended('You stopped it. Nothing of it is left running on the server.'); };
  const e = $('ed');
  let esc = false;
  e.onkeydown = ev => {
    const mod = ev.metaKey || ev.ctrlKey;
    if (mod && ev.key === 'Enter') { ev.preventDefault(); run(ev.shiftKey); return; }
    if (ev.key === 'Escape') { esc = true; return; }
    if (ev.key === 'Tab' && !esc && !ev.shiftKey) { ev.preventDefault(); e.setRangeText('  ', e.selectionStart, e.selectionEnd, 'end'); pos(); return; }
    esc = false;
  };
  e.oninput = () => { pos(); clearTimeout(draftT); draftT = setTimeout(saveDraft, 800); };
  e.onkeyup = e.onclick = pos;
  document.addEventListener('keydown', ev => {
    const mod = ev.metaKey || ev.ctrlKey, typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
    if (mod && ev.key === '.') { ev.preventDefault(); cancel(); return; }
    if (ev.key === 'Escape') { if (document.activeElement === e) return; $('drawer').hidden = $('hist').hidden = $('keys').hidden = true; return; }
    if (typing || mod || ev.altKey) return;
    if (ev.key === '/') { ev.preventDefault(); tab('tables'); $('filter').focus(); }
    if (ev.key === '?') $('keys').hidden = false;
  });
  window.addEventListener('pagehide', saveDraft);
  // keep the session alive while the page is looked at; notice at once when it is gone
  const ping = () => { if (document.visibilityState === 'visible' && !S.ended) api('/api/ping').catch(() => { }); };
  setInterval(ping, 60000);
  document.addEventListener('visibilitychange', ping);
}

async function boot() {
  theme(0); wire();
  const m = /^#c=([\w-]{20,100})$/.exec(location.hash);
  history.replaceState(null, '', location.pathname);
  try { S.token = sessionStorage.getItem('tando.studio.token') || ''; } catch { }
  if (m) {
    try {
      const r = await fetch('/api/session', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: m[1] }) });
      if (r.ok) { S.token = (await r.json()).token; try { sessionStorage.setItem('tando.studio.token', S.token); } catch { } }
    } catch { }
  }
  if (!S.token) { ended('This link was already used, or it expired (a link works once, within a minute). The studio opens one tab per session.'); return; }
  try { S.info = await api('/api/info'); } catch (e) { if (!(e instanceof Gone)) ended(e.message); return; }
  const i = S.info;
  document.title = i.app + ' · ' + i.db + '@' + i.host + ' · tando studio';
  $('app').textContent = i.app;
  $('app').title = 'This page shows the database of ' + i.app + ' only. Another app: tando db studio <app>';
  $('where').textContent = 'database ' + i.db + ' on ' + i.host + ' · PostgreSQL ' + i.pg_version;
  try { S.key = await crypto.subtle.importKey('raw', Uint8Array.from(atob(i.hkey.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0)), 'AES-GCM', false, ['encrypt', 'decrypt']); } catch { }
  S.hist = (await unseal(LS.get(lsKey('.history')))) || [];
  const d = await unseal(LS.get(lsKey('.draft')));
  $('ed').value = d && d.sql ? d.sql : '-- ' + i.app + ' (read-only). ⌘/Ctrl+Enter runs the statement at the cursor.\nSELECT now(), current_user, version();\n';
  status('Read-only: each run is one read-only transaction, always rolled back. Statements stop after ' + i.limits.timeout_ms / 1000 + ' s.');
  loadTables();
}
boot();
