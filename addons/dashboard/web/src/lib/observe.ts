// Observability data shaping: the Server page's cloud-console sections, the app's slice stats and
// the Database tab. Pure functions over the snapshot (tested in observe.test.ts); no React.
// Nulls stay nulls: a gap in the data is a gap in the chart, never 0 and never interpolated.
import type { AppDatabase, DbPoint, DbQuery, ExtendedKey, HostMetricPoint, HostMetrics, MetricPoint, MonitoringKey } from "./types";
import type { ChartPoint } from "./shape";
import { fmtBytes, fmtBytesFine, fmtBytesPerSec, fmtLoad, fmtMsFine, fmtNum, fmtPct, fmtPerMin, fmtPerSec, fmtSecs } from "./format";

export interface MultiPoint extends ChartPoint { s: (number | null)[] }
export type Unit = "raw" | "perSec" | "perMin";

/** one array of `extended` or `monitoring` as chart points (null where not known or where the server has none) */
export function extPoints(m: HostMetrics, group: "extended" | "monitoring", key: ExtendedKey | MonitoringKey, unit: Unit = "raw", div = 1): ChartPoint[] {
  const col = ((m[group] ?? {}) as Record<string, (number | null)[] | undefined>)[key];
  const b = m.bucket_s || 60;
  const rate = (x: number) => (unit === "perSec" ? x / b : unit === "perMin" ? (x * 60) / b : x) / div;
  return m.series.map((p, i) => {
    const x = col?.[i];
    return { t: p.t, v: x == null ? null : rate(x) };
  });
}

/** used / total of the main series, as a percentage per bucket */
export function pctPoints(series: HostMetricPoint[], used: "disk_used_bytes" | "memory_used_bytes", total: "disk_total_bytes" | "memory_total_bytes"): ChartPoint[] {
  return series.map((p) => {
    const a = p[used], b = p[total];
    return { t: p.t, v: a == null || !b ? null : (a / b) * 100 };
  });
}

/** lines of one chart on the same buckets; v is the stack's height (stacked) or the highest line */
export function multiPoints(lines: ChartPoint[][], stack: boolean): MultiPoint[] {
  const n = lines[0]?.length ?? 0;
  const out: MultiPoint[] = [];
  for (let i = 0; i < n; i++) {
    const s = lines.map((l) => l[i]?.v ?? null);
    const have = s.filter((x): x is number => x != null);
    out.push({ t: lines[0][i].t, s, v: have.length === 0 ? null : stack ? have.reduce((a, b) => a + b, 0) : Math.max(...have) });
  }
  return out;
}

export type FmtKey = "pct" | "bytes" | "bytesFine" | "bytesPerSec" | "perSec" | "perMin" | "ms" | "num" | "load" | "secs";
export const FMT: Record<FmtKey, (n: number) => string> = {
  pct: fmtPct, bytes: fmtBytes, bytesFine: fmtBytesFine, bytesPerSec: fmtBytesPerSec, perSec: fmtPerSec, perMin: fmtPerMin, ms: fmtMsFine, num: fmtNum, load: fmtLoad, secs: fmtSecs,
};
export interface Src { g: "extended" | "monitoring" | "series"; key: string; unit?: Unit; div?: number }
export interface LineSpec { name: string; color: string; src: Src }
export interface ChartSpec {
  id: string; title: string; fmt: FmtKey;
  src?: Src; color?: string;         // a single line
  lines?: LineSpec[]; stack?: boolean; // several
  pctOf?: { used: "disk_used_bytes"; total: "disk_total_bytes" }; // disk usage as %
  limit?: "cores" | "memTotal";      // the dashed line (cores of the server, RAM)
  yMax?: "total:swap_total_bytes" | "pct" | "full"; // swap: the axis is the swap size; pct: a round number up to 100; full: 0 to 100
  note?: string;
}
export interface SectionSpec { id: string; title: string; charts: ChartSpec[] }

const E = (key: ExtendedKey, unit?: Unit, div?: number): Src => ({ g: "extended", key, unit, div });
const M = (key: MonitoringKey, unit?: Unit): Src => ({ g: "monitoring", key, unit });
const c = (n: number) => `var(--chart-${n})`;

/** Steal (time the hypervisor took) and swap are information, not alarms: no warn or fail colour anywhere in here */
export const HOST_SECTIONS: SectionSpec[] = [
  { id: "cpu", title: "CPU", charts: [
    { id: "cpu", title: "CPU", fmt: "pct", stack: true, yMax: "pct", lines: [
      { name: "User", color: c(1), src: E("cpu_user_pct") }, { name: "System", color: c(2), src: E("cpu_system_pct") },
      { name: "I/O wait", color: c(3), src: E("cpu_iowait_pct") }, { name: "Steal", color: "var(--faint)", src: E("cpu_steal_pct") }] },
    { id: "load", title: "Load", fmt: "load", src: { g: "series", key: "load" }, color: c(1), limit: "cores" },
  ] },
  { id: "memory", title: "Memory", charts: [
    { id: "mem", title: "Memory", fmt: "bytes", limit: "memTotal", lines: [
      { name: "Used", color: c(1), src: { g: "series", key: "memory_used_bytes" } }, { name: "Cached", color: c(3), src: E("mem_cached_bytes") },
      { name: "Available", color: c(4), src: E("mem_available_bytes") }] },
    { id: "swap", title: "Swap used", fmt: "bytes", src: E("swap_used_bytes"), color: c(4), yMax: "total:swap_total_bytes" },
    { id: "swap-io", title: "Swap in and out", fmt: "perMin", lines: [
      { name: "In", color: c(1), src: E("swap_in_pages", "perMin") }, { name: "Out", color: c(2), src: E("swap_out_pages", "perMin") }], note: "pages a minute" },
  ] },
  { id: "disk", title: "Disk", charts: [
    { id: "disk-use", title: "Disk usage", fmt: "pct", pctOf: { used: "disk_used_bytes", total: "disk_total_bytes" }, color: c(4), yMax: "full" },
    { id: "inodes", title: "Inodes used", fmt: "pct", src: E("inodes_pct"), color: c(5), yMax: "full" },
    { id: "iops", title: "IOPS", fmt: "perSec", lines: [
      { name: "Reads", color: c(1), src: E("disk_reads", "perSec") }, { name: "Writes", color: c(2), src: E("disk_writes", "perSec") }] },
    { id: "throughput", title: "Throughput", fmt: "bytesPerSec", lines: [
      { name: "Read", color: c(1), src: E("disk_read_bytes", "perSec") }, { name: "Write", color: c(2), src: E("disk_write_bytes", "perSec") }] },
    { id: "latency", title: "Latency", fmt: "ms", src: E("disk_latency_us", "raw", 1000), color: c(3) },
    { id: "util", title: "Busy time", fmt: "pct", src: E("disk_util_pct"), color: c(6), yMax: "pct" },
  ] },
  { id: "network", title: "Network", charts: [
    { id: "net", title: "Traffic", fmt: "bytesPerSec", lines: [
      { name: "In", color: c(1), src: E("net_in_bytes", "perSec") }, { name: "Out", color: c(2), src: E("net_out_bytes", "perSec") }] },
    { id: "net-err", title: "Errors and drops", fmt: "perMin", lines: [
      { name: "Errors", color: c(6), src: E("net_errors", "perMin") }, { name: "Drops", color: c(5), src: E("net_drops", "perMin") }] },
    { id: "tcp", title: "TCP connections", fmt: "num", src: E("tcp_established"), color: c(3) },
    { id: "tcp-retr", title: "TCP retransmits", fmt: "perMin", src: E("tcp_retransmits", "perMin"), color: c(2) },
  ] },
  { id: "pressure", title: "Pressure", charts: [
    { id: "psi", title: "Pressure stall", fmt: "pct", yMax: "pct", lines: [
      { name: "CPU", color: c(1), src: E("psi_cpu_pct") }, { name: "Memory", color: c(2), src: E("psi_memory_pct") }, { name: "I/O", color: c(3), src: E("psi_io_pct") }],
      note: "share of time tasks waited" },
  ] },
  { id: "monitoring", title: "Monitoring cost", charts: [
    { id: "mon-cpu", title: "tandod CPU", fmt: "num", src: M("cpu_ms"), color: c(1), note: "ms a minute" },
    { id: "mon-mem", title: "tandod memory", fmt: "bytes", lines: [
      { name: "Anonymous", color: c(1), src: M("anon_bytes") }, { name: "File", color: c(3), src: M("file_bytes") }] },
    { id: "mon-progs", title: "Programs started", fmt: "perMin", src: M("children", "perMin"), color: c(4) },
    { id: "mon-reqs", title: "Reader requests", fmt: "perMin", src: M("requests", "perMin"), color: c(2) },
  ] },
];

/** the app Overview's slice row: the newest known value of each (OOM kills: the sum over the range) */
export interface SliceStats { throttled: number | null; oomKills: number | null; tasks: number | null; tasksMax: number | null; pressure: number | null }
export function appSliceStats(series: MetricPoint[] | undefined): SliceStats {
  const s = series ?? [];
  const last = (k: "throttled_pct" | "tasks" | "tasks_max" | "memory_pressure_pct") => {
    for (let i = s.length - 1; i >= 0; i--) { const v = s[i][k]; if (v != null) return v; }
    return null;
  };
  let oom: number | null = null;
  for (const p of s) if (p.oom_kills != null) oom = (oom ?? 0) + p.oom_kills;
  return { throttled: last("throttled_pct"), oomKills: oom, tasks: last("tasks"), tasksMax: last("tasks_max"), pressure: last("memory_pressure_pct") };
}

export type DbKey = Exclude<keyof DbPoint, "t">;
export function dbPoints(series: DbPoint[] | undefined, key: DbKey): ChartPoint[] {
  return (series ?? []).map((p) => ({ t: p.t, v: p[key] ?? null }));
}

/** size growth a day, from the first and the last known size of the range */
export function dbGrowthPerDay(series: Pick<DbPoint, "t" | "size_bytes">[]): number | null {
  const k = series.filter((p) => p.size_bytes != null);
  if (k.length < 2) return null;
  const a = k[0], b = k[k.length - 1];
  if (b.t <= a.t) return null;
  return ((b.size_bytes! - a.size_bytes!) / (b.t - a.t)) * 86400;
}

/** query text for a table cell: whitespace folded, cut with an ellipsis. Text only: it is rendered as text, never as HTML */
export function truncateQuery(q: string, max = 140): string {
  const t = q.replace(/\s+/g, " ").trim();
  return t.length <= max ? t : t.slice(0, max - 1) + "…";
}
export interface QueryRow { text: string; full: string; calls: number | null; meanMs: number | null; totalMs: number | null; rows: number | null }
export function queryRows(tq: AppDatabase["top_queries"] | undefined): QueryRow[] {
  return (tq?.queries ?? []).map((q: DbQuery) => ({ text: truncateQuery(q.query), full: q.query, calls: q.calls, meanMs: q.mean_ms, totalMs: q.total_ms, rows: q.rows }));
}

/** transaction-id wraparound: said only when it starts to matter (autovacuum normally keeps it near 0) */
export function wrapNote(pct: number | null | undefined): string | null {
  if (pct == null || pct < 50) return null;
  return `${Math.round(pct)}% of the way to transaction-id wraparound. Run a VACUUM FREEZE soon.`;
}

export interface DbChartSpec {
  id: string; title: string; fmt: FmtKey; note?: string;
  lines: { name: string; color: string; key: DbKey }[];
  stack?: boolean; limit?: "max_connections"; yMax?: "full";
}
/** The Database tab's charts, in order. Gaps stay gaps; no warn or fail colour in a series. */
export const DB_CHARTS: DbChartSpec[] = [
  { id: "conns", title: "Connections", fmt: "num", stack: true, limit: "max_connections", lines: [
    { name: "Active", color: c(1), key: "active" }, { name: "Idle", color: c(3), key: "idle" },
    { name: "Idle in transaction", color: c(2), key: "idle_in_transaction" }, { name: "Waiting", color: c(4), key: "waiting" }] },
  { id: "tx", title: "Transactions", fmt: "perSec", lines: [
    { name: "Commits", color: c(1), key: "commits_per_s" }, { name: "Rollbacks", color: c(2), key: "rollbacks_per_s" }] },
  { id: "rows", title: "Rows", fmt: "perSec", lines: [
    { name: "Returned", color: c(1), key: "rows_returned_per_s" }, { name: "Fetched", color: c(3), key: "rows_fetched_per_s" },
    { name: "Inserted", color: c(2), key: "rows_inserted_per_s" }, { name: "Updated", color: c(4), key: "rows_updated_per_s" },
    { name: "Deleted", color: c(5), key: "rows_deleted_per_s" }] },
  { id: "cache", title: "Cache hit", fmt: "pct", yMax: "full", lines: [{ name: "Cache hit", color: c(3), key: "cache_hit_pct" }] },
  { id: "deadlocks", title: "Deadlocks", fmt: "num", lines: [{ name: "Deadlocks", color: c(6), key: "deadlocks" }], note: "per bucket" },
  { id: "temp", title: "Temp files", fmt: "bytesFine", lines: [{ name: "Temp bytes", color: c(4), key: "temp_bytes" }], note: "written to disk per bucket" },
  { id: "long", title: "Longest transaction", fmt: "secs", lines: [
    { name: "Transaction", color: c(1), key: "longest_transaction_s" }, { name: "Idle in transaction", color: c(2), key: "longest_idle_in_transaction_s" }] },
  { id: "size", title: "Size", fmt: "bytes", lines: [{ name: "Size", color: c(4), key: "size_bytes" }] },
];
