// Data shaping for the M5 pages: traffic, error groups, jobs, env, what changed, the deploy timeline
// and alerts. Pure and tested against test/fixtures/json.
import type { Alert, HistoryRow, Release } from "./types";
import type { ChartPoint } from "./shape";
import { resultKind, type Kind } from "./shape";

// ---- shapes of the extra read calls (test/fixtures/json/*.schema); `data` of tando-dash's answer ----
type N = number | null;
export interface Requests {
  host: string; app: string; window_s: number; from: N; to: N; bucket_s: number; total: N;
  status_classes: Record<string, N>; p50_ms: N; p95_ms: N; p99_ms: N; max_ms: N; avg_ms: N; unparsed: N;
  series: { t: number; requests: number; c5xx: number }[];
  codes: { code: N; count: number }[];
  paths: { path: string | null; count: number; mean_ms: N; max_ms: N; count_5xx: N }[];
}
export interface ErrorGroup {
  id: string; count: number; total: N; first_seen: N; last_seen: N; release: string | null; kind: string | null;
  label: string | null; title: string | null; series: { t: number; count: number }[];
}
export interface ErrorsData { host: string; app: string; errors: ErrorGroup[] }
export interface JobRun { at: number; result: string | null; duration_s: N }
export interface Job {
  name: string; schedule: string | null; state: string | null; next_run: N; last_run: N; result: string | null;
  exit_code: N; duration_s: N; command: string | null; next_runs: string[]; runs?: JobRun[];
}
export interface JobsData { host: string; app: string; zone: string | null; zone_name: string | null; jobs: Job[] }
export interface EnvNames { host: string; app: string; names: string[] }
export interface EnvEntry { n: number; time: string; by: string | null; verb: string; note: string | null; added: string[]; changed: string[]; removed: string[] }
export interface EnvLog { host: string; app: string; entries: EnvEntry[] }
export interface AlertEvent { at: N; event: string | null; app: string; check: string | null; detail: string | null }
export interface Notifier { name: string; type: string | null; last_ok: N; failures: N; queued: N; error: string | null }
export interface AlertsData {
  host: string; reachable: boolean; checked_at: N;
  alerts: (Alert & { silenced: boolean })[]; notifiers: Notifier[]; history: AlertEvent[];
}

// ---- traffic ----
const CLASSES = ["2xx", "3xx", "4xx", "5xx", "1xx"] as const;
export interface ClassShare { cls: string; n: number; pct: number }
/** status-class totals for the stacked bar; classes with no requests are left out */
export function classShares(r: Pick<Requests, "status_classes" | "total">): ClassShare[] {
  const sum = CLASSES.reduce((s, c) => s + (r.status_classes[c] ?? 0), 0);
  if (sum <= 0) return [];
  return CLASSES.filter((c) => (r.status_classes[c] ?? 0) > 0).map((c) => ({ cls: c, n: r.status_classes[c] as number, pct: ((r.status_classes[c] as number) / sum) * 100 }));
}
/** requests per minute (the series is per `bucket_s`): the total line, and the 5xx as `w` */
export function perMinute(r: Pick<Requests, "series" | "bucket_s">): ChartPoint[] {
  const k = r.bucket_s > 0 ? 60 / r.bucket_s : 1;
  return r.series.map((p) => ({ t: p.t, v: p.requests * k, w: p.c5xx * k }));
}
/** slowest paths by mean time, then count; the 5xx share rides along */
export function slowestPaths(r: Pick<Requests, "paths">, limit = 10): Requests["paths"] {
  return [...r.paths].filter((p) => p.path).sort((a, b) => (b.mean_ms ?? -1) - (a.mean_ms ?? -1) || b.count - a.count).slice(0, limit);
}
/** "GET /api/items/:n": the method is muted by the page, the path is mono */
export function splitPath(p: string | null): { method: string | null; path: string } {
  const m = /^([A-Z]{3,7}) (.*)$/.exec(p ?? "");
  return m ? { method: m[1], path: m[2] } : { method: null, path: p ?? "" };
}
/** error groups: newest last_seen first; the 7-day sparkline values (per hour) as they are */
export function errorGroups(e: ErrorsData | null | undefined): (ErrorGroup & { spark: (number | null)[] })[] {
  return [...(e?.errors ?? [])].sort((a, b) => (b.last_seen ?? 0) - (a.last_seen ?? 0) || b.count - a.count)
    .map((g) => ({ ...g, spark: g.series.map((s) => s.count) }));
}

// ---- jobs ----
export interface RunBar { at: number; result: Kind; word: string; duration_s: number | null; h: number } // h: 0..1 of the tallest
/** one bar per past run where the data has it; the CLI gives the last run only, so a job without `runs` has at most one */
export function jobRuns(j: Job, max = 20): JobRun[] {
  const runs = j.runs && j.runs.length ? j.runs : j.last_run != null ? [{ at: j.last_run, result: j.result, duration_s: j.duration_s }] : [];
  return [...runs].sort((a, b) => b.at - a.at).slice(0, max);
}
export function runBars(runs: JobRun[], tallest?: number): RunBar[] {
  const top = tallest ?? Math.max(0, ...runs.map((r) => r.duration_s ?? 0));
  return [...runs].reverse().map((r) => {
    const k = resultKind(r.result);
    return { at: r.at, result: k.kind, word: k.word, duration_s: r.duration_s, h: top > 0 && r.duration_s != null ? Math.max(0.08, r.duration_s / top) : 0.08 };
  });
}
export function jobState(state: string | null): { kind: Kind; word: string } {
  switch (state) { case "on": return { kind: "ok", word: "on" }; case "paused": return { kind: "neutral", word: "paused" }; default: return { kind: "stale", word: state ?? "unknown" }; }
}
/** jobs with the next run first; paused ones (no next run) last */
export function jobsOrder(jobs: Job[]): Job[] {
  return [...jobs].sort((a, b) => (a.next_run ?? Infinity) - (b.next_run ?? Infinity) || a.name.localeCompare(b.name));
}

// ---- env ----
const ENV_TIME = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})(?::(\d{2}))?(?: UTC| GMT)?$/;
/** "2026-11-21 06:42 UTC" -> unix seconds (null when it is not that shape) */
export function envTime(s: string | null | undefined): number | null {
  const m = ENV_TIME.exec(s ?? "");
  return m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? 0)) / 1000 : null;
}
export interface EnvRow { key: string; changedAt: number | null; note: string | null; by: string | null }
/** key names with when they last changed and the note of that change; never a value */
export function envRows(names: string[] | undefined, log: EnvEntry[] | undefined): EnvRow[] {
  const entries = [...(log ?? [])].sort((a, b) => (envTime(b.time) ?? 0) - (envTime(a.time) ?? 0) || b.n - a.n);
  return [...(names ?? [])].sort().map((key) => {
    const e = entries.find((x) => x.added.includes(key) || x.changed.includes(key));
    return { key, changedAt: e ? envTime(e.time) : null, note: e ? cleanNote(e.note) : null, by: e?.by ?? null };
  });
}
export const cleanNote = (n: string | null | undefined): string | null => (!n || n === "-" ? null : n);
export function envAction(e: EnvEntry): string {
  return e.verb === "import" ? "import" : e.removed.length && !e.added.length && !e.changed.length ? "unset" : e.verb;
}
/** the keys of one entry, with what happened to each: "+DATABASE_URL ~SESSION_SECRET -OLD" */
export function envKeys(e: EnvEntry): { key: string; op: "added" | "changed" | "removed" }[] {
  return [...e.added.map((key) => ({ key, op: "added" as const })), ...e.changed.map((key) => ({ key, op: "changed" as const })), ...e.removed.map((key) => ({ key, op: "removed" as const }))];
}

// ---- what changed ----
export interface Changes { from: Release | null; to: Release | null; deploys: HistoryRow[]; notes: HistoryRow[]; env: EnvEntry[]; empty: boolean }
/** previous live -> live: `to` is the live release, `from` the one before it in deploy order */
export function defaultPair(releases: Release[]): { from: string; to: string } | null {
  const sorted = [...releases].sort((a, b) => (b.deployed_at ?? 0) - (a.deployed_at ?? 0));
  const live = sorted.find((r) => r.current) ?? sorted[0];
  if (!live) return null;
  const prev = sorted.find((r) => r.id !== live.id && (r.deployed_at ?? 0) <= (live.deployed_at ?? 0));
  return prev ? { from: prev.id, to: live.id } : { from: live.id, to: live.id };
}
/** everything deployed after `from`, up to and including `to`; the two may be given in either order */
export function changesBetween(releases: Release[], history: HistoryRow[], env: EnvEntry[] | null | undefined, fromId: string, toId: string): Changes {
  let a = releases.find((r) => r.id === fromId) ?? null, b = releases.find((r) => r.id === toId) ?? null;
  if (a && b && (a.deployed_at ?? 0) > (b.deployed_at ?? 0)) [a, b] = [b, a];
  const lo = a?.deployed_at ?? null, hi = b?.deployed_at ?? null;
  if (lo == null || hi == null || a?.id === b?.id) return { from: a, to: b, deploys: [], notes: [], env: [], empty: true };
  // a deploy belongs between when its release was deployed after `from` (up to `to`), or it is a rollback that ran in that time
  const ids = new Set(releases.filter((r) => (r.deployed_at ?? 0) > lo && (r.deployed_at ?? 0) <= hi).map((r) => r.id));
  const deploys = history.filter((h) => ids.has(h.release) || (h.kind === "rollback" && h.at > lo && h.at <= hi)).sort((x, y) => y.at - x.at);
  const notes = deploys.filter((h) => !!h.note && h.note !== "-");
  const e = (env ?? []).filter((x) => { const t = envTime(x.time); return t != null && t > lo && t <= hi; }).sort((x, y) => (envTime(y.time) ?? 0) - (envTime(x.time) ?? 0));
  return { from: a, to: b, deploys, notes, env: e, empty: deploys.length === 0 && e.length === 0 };
}

// ---- deploy timeline (all apps) ----
export interface TimelineRow extends HistoryRow { host: string }
export interface TimelineFilter { host: string; app: string; result: string }
export const NO_TIMELINE_FILTER: TimelineFilter = { host: "", app: "", result: "" };
export function timeline(rows: TimelineRow[], f: TimelineFilter = NO_TIMELINE_FILTER): TimelineRow[] {
  return rows.filter((r) => (!f.host || r.host === f.host) && (!f.app || r.app === f.app) && (!f.result || resultKind(r.result).word === f.result))
    .sort((a, b) => b.at - a.at || a.app.localeCompare(b.app));
}
/** a deploy on two hosts of the same app and time stays two rows; this key is unique per row */
export const timelineKey = (r: TimelineRow) => `${r.host}/${r.app}/${r.at}/${r.release}/${r.kind}`;
export function timelineOptions(rows: TimelineRow[]): { hosts: string[]; apps: string[]; results: string[] } {
  const u = (f: (r: TimelineRow) => string) => [...new Set(rows.map(f))].sort();
  return { hosts: u((r) => r.host), apps: u((r) => r.app), results: u((r) => resultKind(r.result).word) };
}

// ---- alerts ----
export interface AlertRow extends Alert { host: string; silenced: boolean }
/** firing first, then pending; across hosts, newest since first inside each */
export function alertRows(hosts: { host: string; alerts: (Alert & { silenced?: boolean })[] | undefined }[]): { firing: AlertRow[]; pending: AlertRow[] } {
  const all = hosts.flatMap((h) => (h.alerts ?? []).map((a) => ({ ...a, host: h.host, silenced: !!a.silenced })));
  const by = (s: (a: AlertRow) => boolean) => all.filter(s).sort((a, b) => (b.since ?? 0) - (a.since ?? 0) || a.host.localeCompare(b.host) || a.app.localeCompare(b.app));
  return { firing: by((a) => a.state === "firing"), pending: by((a) => a.state !== "firing") };
}
export interface AlertSpan { host: string; app: string; check: string; detail: string | null; from: number | null; to: number | null; durationS: number | null }
/** events (fire / resolve) -> spans: a resolve closes the open fire of the same app and check */
export function alertSpans(events: (AlertEvent & { host: string })[], nowS: number, sinceS = nowS - 7 * 86400): AlertSpan[] {
  const asc = [...events].filter((e) => e.at != null).sort((a, b) => (a.at as number) - (b.at as number));
  const open = new Map<string, AlertSpan>();
  const out: AlertSpan[] = [];
  for (const e of asc) {
    const k = `${e.host}/${e.app}/${e.check}`;
    if (e.event === "fire") {
      const prev = open.get(k);
      if (prev) out.push(prev); // a second fire without a resolve: keep the first as it was
      open.set(k, { host: e.host, app: e.app, check: e.check ?? "", detail: e.detail, from: e.at, to: null, durationS: null });
    } else if (e.event === "resolve") {
      const s = open.get(k);
      if (s) { s.to = e.at; s.durationS = (e.at as number) - (s.from as number); out.push(s); open.delete(k); }
      else out.push({ host: e.host, app: e.app, check: e.check ?? "", detail: e.detail, from: null, to: e.at, durationS: null });
    }
  }
  open.forEach((s) => out.push(s));
  return out.filter((s) => (s.to ?? s.from ?? nowS) >= sinceS).sort((a, b) => (b.to ?? nowS + 1) - (a.to ?? nowS + 1) || (b.from ?? 0) - (a.from ?? 0));
}
