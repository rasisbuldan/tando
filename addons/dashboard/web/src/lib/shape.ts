// Data shaping: everything the pages derive from tando's JSON, pure and tested against the fixtures.
import type { Alert, AppRow, HistoryRow, HostView, Metrics, Release, Snapshot, ApiErrorBody, MetricPoint } from "./types";
import { share } from "./share";

export type Kind = "ok" | "warn" | "fail" | "stale" | "info" | "neutral";

/** state_reason -> badge. tando's words; never re-derived from other fields (spec S4). */
export function appKind(a: Pick<AppRow, "state_reason" | "state">): { kind: Kind; word: string } {
  switch (a.state_reason) {
    case "running": return { kind: "ok", word: "running" };
    case "static": return { kind: "neutral", word: "static" };
    case "deploying": return { kind: "info", word: "deploying" };
    case "stopped": return { kind: "neutral", word: "stopped" };
    case "down": return { kind: "fail", word: "down" };
    case "failed": return { kind: "fail", word: "failed" };
    case "not_deployed": return { kind: "neutral", word: "never deployed" };
    default: return { kind: "stale", word: a.state ?? "unknown" };
  }
}
const KIND_RANK: Record<Kind, number> = { fail: 0, warn: 1, stale: 2, info: 3, ok: 4, neutral: 5 };
export const kindRank = (k: Kind) => KIND_RANK[k];

/** "down · exited": the state with the detail of the app's own firing alert */
export function stateWithReason(a: AppRow, alerts: Alert[] | undefined): string {
  const { word } = appKind(a);
  if (a.state_reason === "down" || a.state_reason === "failed") {
    const al = alerts?.find((x) => x.app === a.app && x.state === "firing" && x.detail);
    if (al?.detail) return `${word} · ${al.detail}`;
  }
  return word;
}

export function resultKind(result: string | null): { kind: Kind; word: string } {
  switch (result) {
    case "verified": case "ok": case "success": return { kind: "ok", word: "verified" };
    case "failed": return { kind: "fail", word: "failed" };
    case "rolled back": case "rolled_back": return { kind: "warn", word: "rolled back" };
    case null: case undefined: case "": return { kind: "stale", word: "unknown" };
    default: return { kind: "neutral", word: result };
  }
}

// ---- host views: last good data is never blanked ----

export interface RawHost { host: string; ok: boolean; fetched_at?: string; data?: Snapshot; error?: ApiErrorBody }

function parseTime(s: string | undefined): number | null {
  if (!s) return null;
  const t = Date.parse(s);
  return Number.isNaN(t) ? null : Math.floor(t / 1000);
}

/** one poll's answer as host views, before the previous ones are merged in */
export function toViews(raw: RawHost[]): HostView[] {
  return raw.map((h) => {
    if (h.ok && h.data) {
      if (h.data.reachable === false) {
        return { host: h.host, data: null, fetchedAtS: null, error: h.data.error ?? "not answering", reachable: false };
      }
      return { host: h.host, data: h.data, fetchedAtS: parseTime(h.fetched_at) ?? h.data.checked_at, error: null, reachable: true };
    }
    return { host: h.host, data: null, fetchedAtS: null, error: h.error?.message ?? "not answering", reachable: false };
  });
}

/** keep a failed host's last data (marked by `error`), share unchanged objects, order by name */
export function mergeViews(prev: HostView[] | null, next: HostView[]): HostView[] {
  const old = new Map((prev ?? []).map((h) => [h.host, h]));
  const out = next.map((h) => {
    const o = old.get(h.host);
    if (!h.data && o?.data) return { ...h, data: o.data, fetchedAtS: o.fetchedAtS, reachable: false };
    if (h.data && o?.data) return { ...h, data: share(o.data, h.data) };
    return h;
  }).sort((a, b) => a.host.localeCompare(b.host));
  return share(prev, out);
}

// ---- needs attention ----

export interface Attention { key: string; kind: Kind; word: string; host: string; app: string | null; what: string; since: number | null }

export function needsAttention(hosts: HostView[]): Attention[] {
  const out: Attention[] = [];
  for (const h of hosts) {
    if (!h.reachable) {
      out.push({ key: `h:${h.host}`, kind: "fail", word: "not answering", host: h.host, app: null, what: h.error ?? "ssh timed out", since: h.fetchedAtS });
    }
    const d = h.data;
    if (!d) continue;
    for (const a of d.alerts ?? []) {
      const firing = a.state === "firing";
      out.push({
        key: `a:${h.host}:${a.app}:${a.check}`, kind: firing ? "fail" : "warn", word: firing ? "firing" : "pending",
        host: h.host, app: a.app === "host" ? null : a.app, what: [a.check, a.detail].filter(Boolean).join(" · "), since: a.since,
      });
    }
    for (const a of d.apps ?? []) {
      if (a.state_reason !== "down" && a.state_reason !== "failed") continue;
      // the down alert already says it: one row per problem
      if ((d.alerts ?? []).some((x) => x.app === a.app && x.check === "down")) continue;
      out.push({ key: `s:${h.host}:${a.app}`, kind: "fail", word: a.state_reason, host: h.host, app: a.app, what: `app ${a.state_reason}`, since: null });
    }
  }
  return out.sort((a, b) => kindRank(a.kind) - kindRank(b.kind) || a.host.localeCompare(b.host) || (a.app ?? "").localeCompare(b.app ?? ""));
}

// ---- the all-apps table ----

export interface AppTableRow extends AppRow { host: string; stale: boolean }
export type SortKey = "state" | "app" | "host" | "release" | "memory" | "cpu" | "restarts" | "uptime" | "deployed" | "alerts";
export interface Sort { key: SortKey; dir: "asc" | "desc" }

export function appRows(hosts: HostView[]): AppTableRow[] {
  return hosts.flatMap((h) => (h.data?.apps ?? []).map((a) => ({ ...a, host: h.host, stale: !h.reachable })));
}

/** the default order: attention first, then name */
export function defaultOrder(rows: AppTableRow[]): AppTableRow[] {
  return [...rows].sort((a, b) => {
    const ka = a.stale ? "stale" : appKind(a).kind, kb = b.stale ? "stale" : appKind(b).kind;
    return kindRank(ka) - kindRank(kb) || a.app.localeCompare(b.app) || a.host.localeCompare(b.host);
  });
}

const val = (r: AppTableRow, k: SortKey): number | string | null => {
  switch (k) {
    case "state": return kindRank(r.stale ? "stale" : appKind(r).kind);
    case "app": return r.app; case "host": return r.host; case "release": return r.release;
    case "memory": return r.memory_bytes && r.memory_bytes > 0 ? r.memory_bytes : null;
    case "cpu": return r.cpu_percent; case "restarts": return r.restarts; case "uptime": return r.uptime_s && r.uptime_s > 0 ? r.uptime_s : null;
    case "deployed": return r.deployed_at; case "alerts": return r.alerts_firing;
  }
};
/** user sort: missing values last in both directions; ties by app then host so it is stable */
export function sortRows(rows: AppTableRow[], s: Sort | null): AppTableRow[] {
  if (!s) return defaultOrder(rows);
  const m = s.dir === "asc" ? 1 : -1;
  return [...rows].sort((a, b) => {
    const x = val(a, s.key), y = val(b, s.key);
    if (x == null && y != null) return 1;
    if (y == null && x != null) return -1;
    if (x != null && y != null && x !== y) return (x < y ? -1 : 1) * m;
    return a.app.localeCompare(b.app) || a.host.localeCompare(b.host);
  });
}
/** keep rows in place on polls: order the new rows by the previous key order, new ones last */
export function keepOrder(order: string[], rows: AppTableRow[]): AppTableRow[] {
  const idx = new Map(order.map((k, i) => [k, i]));
  return [...rows].sort((a, b) => (idx.get(rowKey(a)) ?? 1e9) - (idx.get(rowKey(b)) ?? 1e9));
}
export const rowKey = (r: { host: string; app: string }) => `${r.host}/${r.app}`;

/** next sort on a header click: new key starts desc (text keys asc), same key toggles */
export function nextSort(cur: Sort | null, key: SortKey): Sort {
  if (cur?.key === key) return { key, dir: cur.dir === "desc" ? "asc" : "desc" };
  return { key, dir: key === "app" || key === "host" || key === "release" ? "asc" : "desc" };
}

// ---- host figures ----

/** "clock 42 s ahead" when the server clock differs by more than 30 s, else null */
export function skewNote(skew: number | null | undefined): string | null {
  if (skew == null || Math.abs(skew) <= 30) return null;
  return `clock ${Math.abs(Math.round(skew))} s ${skew > 0 ? "ahead" : "behind"}`;
}

/** sum of the apps' memory caps against the RAM */
export function headroom(apps: AppRow[] | undefined, ramBytes: number | null | undefined): { capBytes: number; ramBytes: number; pct: number } | null {
  if (!apps || !ramBytes) return null;
  const cap = apps.reduce((s, a) => s + (a.memory_max_bytes ?? 0), 0);
  if (cap <= 0) return null;
  return { capBytes: cap, ramBytes, pct: (cap / ramBytes) * 100 };
}

export function worstKind(kinds: Kind[]): Kind {
  return kinds.length ? kinds.reduce((a, b) => (kindRank(a) <= kindRank(b) ? a : b)) : "neutral";
}

// ---- charts ----

export type RangeKey = "1h" | "24h" | "7d";
export const RANGE_S: Record<RangeKey, number> = { "1h": 3600, "24h": 86400, "7d": 604800 };

export interface ChartDomain { from: number; to: number }
/** fixed domain [now - range, now], now = the server's clock (the metrics' own `to` as fallback) */
export function chartDomain(range: RangeKey, serverNow: number | null | undefined, m: Metrics | null): ChartDomain {
  const to = serverNow ?? m?.to ?? Math.floor(Date.now() / 1000);
  return { from: to - RANGE_S[range], to };
}

export type SeriesKey = "memory_bytes" | "cpu_percent" | "restarts";
export interface ChartPoint { t: number; v: number | null; w?: number | null } // w: an optional second series (5xx)
/** buckets as points; null stays null (a gap), never zero and never interpolated */
export function toPoints(series: MetricPoint[] | undefined, key: SeriesKey): ChartPoint[] {
  return (series ?? []).map((p) => ({ t: p.t, v: p[key] ?? null }));
}
export interface Gaps { points: number; gaps: number; first: number | null; last: number | null; min: number | null; max: number | null }
export function describe(points: ChartPoint[]): Gaps {
  let gaps = 0, first: number | null = null, last: number | null = null, min: number | null = null, max: number | null = null;
  for (const p of points) {
    if (p.v == null) { gaps++; continue; }
    if (first == null) first = p.v;
    last = p.v;
    min = min == null ? p.v : Math.min(min, p.v);
    max = max == null ? p.v : Math.max(max, p.v);
  }
  return { points: points.length, gaps, first, last, min, max };
}
/** the "data since" label: only when the retained data starts after the domain start */
export function dataSince(m: Metrics | null, domain: ChartDomain): number | null {
  if (!m || m.data_since == null) return null;
  return m.data_since > domain.from + (m.bucket_s || 0) ? m.data_since : null;
}
/** restarts in the range (sum of the per-bucket values the server already clamped at 0) */
export function restartsTotal(points: ChartPoint[]): number { return points.reduce((s, p) => s + (p.v ?? 0), 0); }
/** y axis max: a round number above the data */
export function niceMax(v: number | null): number {
  if (!v || v <= 0) return 1;
  const e = Math.pow(10, Math.floor(Math.log10(v)));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * e >= v) return m * e;
  return 10 * e;
}
/** buckets that are within the data window and in the deploys' times: deploy markers inside the domain */
export interface Marker { t: number; release: string; kind: string; result: string }
export function deployMarkers(history: HistoryRow[] | undefined, d: ChartDomain): Marker[] {
  return (history ?? []).filter((h) => h.at >= d.from && h.at <= d.to).map((h) => ({ t: h.at, release: h.release, kind: h.kind, result: resultKind(h.result).word }));
}
/** the hover text of a deploy marker: "r 20261117-101010 · deploy · verified" */
export function markerText(m: Marker): string { return `r ${m.release} · ${m.kind || "deploy"} · ${m.result}`; }
/** the markers within `within` seconds of a time (a chart hover shows these) */
export function markersNear(markers: Marker[] | undefined, t: number, within: number): Marker[] {
  return (markers ?? []).filter((m) => Math.abs(m.t - t) <= within);
}

/** round y ticks: 0 and equal steps of 1, 2, 2.5 or 5 x 10^n up to `max`, at most `n` of them (memory: bytes in MB, GB when large) */
export function roundTicks(max: number, n = 4, unit = 1): number[] {
  if (!(max > 0)) return [0];
  const top = max / unit;
  const e = Math.pow(10, Math.floor(Math.log10(top / n)));
  const step = ([1, 2, 2.5, 5, 10].map((m) => m * e).find((s) => top / s <= n) ?? 10 * e) * unit;
  const out: number[] = [];
  for (let v = 0; v <= max + step * 1e-9; v += step) out.push(Math.round(v / unit * 1e6) / 1e6 * unit);
  return out;
}
const MB = 1024 * 1024;
/** memory y ticks in whole MB steps (0, 200, 400, 600 MB), or GB steps when the axis is large */
export function memoryTicks(maxBytes: number): number[] { return roundTicks(maxBytes, 4, maxBytes >= 2048 * MB ? 1024 * MB : MB); }
/** CPU axis scaled to the data: at least 10 %, at most 100 %, a round number above the data */
export function cpuMax(dataMax: number | null): number { return Math.min(100, Math.max(10, niceMax(dataMax))); }
/** the previous verified release: the newest one that is not live and was verified */
export function rollbackTarget(releases: Release[]): string | null {
  const t = [...releases].filter((r) => !r.current && (r.status === "verified" || r.status === "ok")).sort((a, b) => (b.deployed_at ?? 0) - (a.deployed_at ?? 0))[0];
  return t?.id ?? null;
}
/** the "No restarts in 24 h" state: data present and all zero */
export function allZero(points: ChartPoint[]): boolean { const v = points.filter((p) => p.v != null); return v.length > 0 && v.every((p) => p.v === 0); }
/** screen-reader summary: "Memory, last 24 h: 380 to 430 MB, now 412 MB, 2 deploys" */
export function chartSummary(name: string, range: RangeKey, g: Gaps, fmt: (n: number) => string, deploys: number): string {
  if (g.last == null) return `${name}, last ${range.replace("h", " h")}: no data in this range yet`;
  return `${name}, last ${range.replace("h", " h")}: ${fmt(g.min ?? 0)} to ${fmt(g.max ?? 0)}, now ${fmt(g.last)}, ${deploys} ${deploys === 1 ? "deploy" : "deploys"}`;
}

// ---- uptime strip ----
export interface Cell { kind: "ok" | "fail" | "none"; t: number }
/** 24 h strip: one cell per metrics bucket; fail inside an incident, ok with data, none without */
export function uptimeCells(m: Metrics | null, incidents: { start: number; end: number | null }[], now: number): Cell[] {
  if (!m) return [];
  return m.series.map((p) => {
    const end = p.t + m.bucket_s;
    const inc = incidents.some((i) => p.t < (i.end ?? now) && end > i.start);
    return { t: p.t, kind: inc ? "fail" : p.memory_bytes == null && p.state == null ? "none" : "ok" };
  });
}

// ---- deploys: phase bars ----
export interface Phase { key: string; label: string; s: number }
export const PHASES: { key: keyof HistoryRow; label: string }[] = [
  { key: "build_s", label: "build" }, { key: "upload_s", label: "upload" }, { key: "release_s", label: "release command" },
  { key: "preflight_s", label: "preflight" }, { key: "switch_s", label: "switch" }, { key: "verify_s", label: "verify" },
];
/** upload includes the copy (DESIGN 6); null phases are left out */
export function phases(h: HistoryRow): Phase[] {
  const out: Phase[] = [];
  for (const p of PHASES) {
    let s = h[p.key] as number | null;
    if (p.key === "upload_s" && (s != null || h.copy_s != null)) s = (s ?? 0) + (h.copy_s ?? 0);
    if (s != null && s > 0) out.push({ key: p.key, label: p.label, s });
  }
  return out;
}

