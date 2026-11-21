// dev only: a reverse proxy in front of tando-dash (8097) that also answers the reads the M5 pages
// need and tando-dash does not serve yet (jobs, requests, errors, envnames, envlog, alerts), from
// test/fixtures/json. Run tando-dash with --port 8097, this proxy on 8099, open the link with port 8099.
//   node dev/extra-api.mjs
import http from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const F = fileURLToPath(new URL("../../../../test/fixtures/json/", import.meta.url));
const MAP = { jobs: "jobs", requests: "requests", errors: "errors", envnames: "env-ls", envlog: "env-log", alerts: "alerts" };
const fix = (h) => { const o = { ...h, host: `127.0.0.1:${UP}` }; for (const k of ["origin", "referer"]) if (o[k]) o[k] = o[k].replace(/:\d+/, `:${UP}`); return o; };
const UP = Number(process.env.TANDO_DASH_PORT || 8097);
http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const m = /^\/api\/([a-z]+)$/.exec(u.pathname);
  if (m && MAP[m[1]] && req.method === "GET") {
    const host = u.searchParams.get("host");
    if (host === "web-2") { res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify({ error: { code: "ssh", message: "ssh timed out" } })); return; }
    const data = JSON.parse(readFileSync(F + MAP[m[1]] + ".sample.json", "utf8"));
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ host, app: u.searchParams.get("app"), ran_at: new Date().toISOString(), cached: false, next_poll_s: 60, data }));
    return;
  }
  const p = http.request({ host: "127.0.0.1", port: UP, path: req.url, method: req.method, headers: fix(req.headers) }, (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
  p.on("error", () => { res.writeHead(502); res.end(); });
  req.pipe(p);
}).listen(Number(process.env.PROXY_PORT || 8099), "127.0.0.1", () => console.log(`dev proxy on http://127.0.0.1:${process.env.PROXY_PORT || 8099} -> tando-dash on ${UP}`));
