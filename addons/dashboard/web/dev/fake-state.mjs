// dev only: the fake tando's snapshot and writes, with state kept in a folder (never touches a
// server). Called by dev/fake-tando.sh. Per app, to try every state of the write UI:
//   shop  deploy: slow (about 12 s of output), then ok; rollback, stop, start, restart: ok
//   docs  deploy: fails at preflight (exit 1)
//   api   restart: busy (another operation holds it); deploy: off (last deployed from another machine)
//   jobs  deploy: off (no record of where it was deployed from); start: ok
//   env set: ok; a key starting with FAIL fails. The value is read from stdin and never printed.
// Two writes of one app at once: tando-dash answers 409 (start a shop deploy, then try again).
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { userInfo, hostname, tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const F = fileURLToPath(new URL("../../../../test/fixtures/json/", import.meta.url));
const ST = process.env.TANDO_FAKE_STATE || join(process.env.TMPDIR || tmpdir(), "tando-dash-dev", "state");
mkdirSync(ST, { recursive: true });
const sf = join(ST, "state.json");
const load = () => { try { return JSON.parse(readFileSync(sf, "utf8")); } catch { return { apps: {} }; } };
const save = (s) => writeFileSync(sf, JSON.stringify(s));
const args = process.argv.slice(2);
const opt = (f) => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : undefined; };
const host = opt("-H");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const me = `${userInfo().username}@${hostname().split(".")[0]}`.replace(/[^A-Za-z0-9_.@-]/g, "").slice(0, 64);
const appState = (s, a) => (s.apps[a] ??= { history: [] });
const stamp = () => { const d = new Date(); const p = (n) => String(n).padStart(2, "0"); return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}-${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`; };

function origin(app) {
  if (app === "jobs") return null;
  if (app === "api") return "someone@another-box:/src/api";
  const dir = join(ST, `proj-${app}`);
  if (!existsSync(dir)) { mkdirSync(dir, { recursive: true }); writeFileSync(join(dir, "tando.conf"), `app = ${app}\n`); }
  return `${me}:${dir}`;
}

function snapshot() {
  if (host === "web-2") { process.stdout.write(readFileSync(F + "snapshot-unreachable.sample.json")); return; }
  const app = opt("--app");
  const d = JSON.parse(readFileSync(F + (app ? "snapshot-app.sample.json" : "snapshot.sample.json"), "utf8"));
  const s = load();
  for (const a of d.apps ?? []) {
    const x = s.apps[a.app];
    if (x?.state) { a.state_reason = x.state; a.state = x.state === "stopped" ? "stopped" : "running"; }
    if (x?.release) a.release = x.release;
  }
  if (app && d.app) {
    const x = s.apps[app] ?? { history: [] };
    d.app.name = app;
    d.app.origin = origin(app);
    d.app.history = [...x.history, ...d.app.history];
    if (d.app.status) Object.assign(d.app.status, (d.apps ?? []).find((a) => a.app === app) ?? {});
    if (x.release) d.app.releases = [{ id: x.release, deployed_at: Math.floor(Date.now() / 1000), status: "verified", current: true, last_good: true },
      ...d.app.releases.map((r) => ({ ...r, current: false }))];
  }
  process.stdout.write(JSON.stringify(d));
}

async function lines(list, ms) { for (const l of list) { console.log(l); await sleep(ms); } }

async function write(verb) {
  const app = verb === "deploy" || verb === "env" ? opt("-a") : args[1];
  const s = load(), x = appState(s, app);
  const hist = (kind, result, release, total, note) => { x.history.unshift({ at: Math.floor(Date.now() / 1000), release, kind, result, total_s: total, note: note ?? null }); };
  if (verb === "deploy") {
    const rel = stamp();
    if (app === "docs") {
      await lines(["tando: building docs", "tando: uploading 3.1 MB", "tando: preflight: starting the new release"], 400);
      hist("deploy", "failed", rel, 4.2, "preflight: health check got 502");
      save(s);
      console.log("tando: preflight: health check got 502 (the live release is unchanged)");
      process.exit(1);
    }
    const out = ["tando: building in " + process.cwd()];
    for (let i = 1; i <= 24; i++) out.push(i < 12 ? `  build step ${i} of 11: compiling module ${i}` : i < 18 ? `tando: uploading ${(i - 11) * 6} of 36 MB` : i < 22 ? "tando: preflight: waiting for /health" : "tando: switching to " + rel);
    await lines(out, 500);
    hist("deploy", "verified", rel, 12.4); x.release = rel; x.state = "running"; save(s);
    console.log(`tando: deployed ${rel} in 12.4 s`);
    return;
  }
  if (verb === "rollback") {
    const to = args[2] && args[2] !== "-H" ? args[2] : "20261116-101010";
    await lines([`tando: rolling ${app} back to ${to}`, "tando: switching", "tando: health check ok"], 600);
    hist("rollback", "ok", to, 1.8); x.release = to; x.state = "running"; save(s);
    console.log(`tando: rolled back to ${to}`);
    return;
  }
  if (verb === "restart" && app === "api") {
    console.log("tando: waiting for the app's lock");
    await sleep(1500);
    console.log("tando: api is busy: a deploy started 14:01 GMT by ci is running");
    process.exit(1);
  }
  if (verb === "stop" || verb === "start" || verb === "restart") {
    await lines([`tando: ${verb === "stop" ? "stopping" : verb === "start" ? "starting" : "restarting"} ${app}`, "tando: waiting for the units"], 700);
    x.state = verb === "stop" ? "stopped" : "running"; save(s);
    console.log(`tando: ${app} is ${x.state}`);
    return;
  }
  if (verb === "env") {
    const key = args[2];
    readFileSync(0); // the value, on stdin: never printed, never stored
    await lines([`tando: setting ${key} on ${app}`, `tando: restarting ${app}`], 700);
    if (key.startsWith("FAIL")) { console.log(`tando: ${app} did not come up healthy; ${key} was not changed`); process.exit(1); }
    console.log(`tando: ${key} set`);
  }
}

const v = args[0];
if (v === "snapshot") snapshot();
else await write(v);
