// Budgets (docs/SPEC.md, DESIGN.md section 12): fails when one is broken. Reads the build in
// ../server/webdist/dist: first route JS <= 150 KB gzipped, CSS <= 15 KB gzipped, Recharts only in a
// chunk the first route does not load, nothing inline (CSP).
import { readFileSync, readdirSync } from "node:fs";
import { gzipSync } from "node:zlib";

const dist = new URL("../../server/webdist/dist/", import.meta.url);
const KB = 1024, JS_MAX = 150, CSS_MAX = 15;
const read = (f) => readFileSync(new URL(f, dist));
const gz = (b) => gzipSync(b, { level: 9 }).length;
const fails = [];
const check = (ok, msg) => { if (!ok) fails.push(msg); console.log(`${ok ? "ok  " : "FAIL"} ${msg}`); };

const html = read("index.html").toString("utf8");
const assets = readdirSync(new URL("assets/", dist));
const entries = [...html.matchAll(/<script[^>]*\ssrc="\/(assets\/[^"]+\.js)"/g)].map((m) => m[1]);
check(entries.length === 1, `index.html loads one app script (${entries.join(", ")})`);

// static import closure (dynamic import() is not followed: that is what lazy means)
function closure(files) {
  const seen = new Set();
  const walk = (f) => {
    if (seen.has(f)) return;
    seen.add(f);
    const src = read(f).toString("utf8");
    for (const m of src.matchAll(/(?:from|import)\s*"\.\/([^"]+\.js)"/g)) walk("assets/" + m[1]);
  };
  files.forEach(walk);
  return seen;
}
const find = (prefix) => assets.filter((a) => a.startsWith(prefix) && a.endsWith(".js")).map((a) => "assets/" + a);
const overview = find("overview-");
check(overview.length === 1, "the Overview route is its own chunk");
const first = closure([...entries, ...overview]);
for (const m of html.matchAll(/<link[^>]*rel="modulepreload"[^>]*href="\/(assets\/[^"]+)"/g)) first.add(m[1]);

let js = 0;
for (const f of first) js += gz(read(f));
check(js <= JS_MAX * KB, `first route JS ${(js / KB).toFixed(1)} KB gzipped <= ${JS_MAX} KB (${first.size} files)`);

const charts = assets.filter((a) => a.endsWith(".js")).map((a) => "assets/" + a).filter((f) => /ResponsiveContainer|recharts/i.test(read(f).toString("utf8")) && read(f).length > 100 * KB);
check(charts.length >= 1, `the Recharts chunk exists (${charts.map((c) => `${c} ${(gz(read(c)) / KB).toFixed(1)} KB gz`).join(", ")})`);
check(charts.every((c) => !first.has(c)), "the first route does not load the Recharts chunk");

const cssFiles = assets.filter((a) => a.endsWith(".css"));
let css = 0, cssRaw = 0;
for (const f of cssFiles) { const b = read("assets/" + f); css += gz(b); cssRaw += b.length; }
check(css <= CSS_MAX * KB, `CSS ${(css / KB).toFixed(1)} KB gzipped (${(cssRaw / KB).toFixed(1)} KB raw) <= ${CSS_MAX} KB`);

check(!/<script(?![^>]*\ssrc=)[^>]*>/.test(html), "index.html has no inline script");
check(!/<style[\s>]/.test(html) && !/\sstyle=/.test(html), "index.html has no inline style");
check(read("theme.js").length <= 400, `theme.js is ${read("theme.js").length} bytes (<= 400)`);

if (fails.length) { console.error(`\n${fails.length} budget check(s) failed`); process.exit(1); }
