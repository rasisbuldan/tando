// Shapes of tando's JSON (test/fixtures/json/*.schema), only the fields the pages read.
export type Num = number | null;

export interface System {
  hostname: string | null; cpus: Num; load_1: Num; load_5: Num; load_15: Num;
  memory_used_bytes: Num; memory_total_bytes: Num; disk_used_bytes: Num; disk_total_bytes: Num; uptime_s: Num;
}
export interface AppRow {
  app: string; state: string | null; recipe: string | null; port: Num; release: string | null;
  deployed_at: Num; release_status: string | null; memory_bytes: Num; memory_max_bytes: Num;
  cpu_percent: Num; restarts: Num; uptime_s: Num; link: string | null; database: string | null;
  alerts_firing: Num; firing: string | null; state_reason: string;
}
export interface Alert { app: string; check: string | null; state: string | null; since: Num; detail: string | null }
export interface Release { id: string; deployed_at: Num; status: string | null; current: boolean; last_good: boolean }
export interface HistoryRow {
  at: number; app: string; release: string; kind: string; result: string; total_s: Num;
  build_s: Num; upload_s: Num; copy_s: Num; release_s: Num; preflight_s: Num; switch_s: Num; verify_s: Num;
  note: string | null; deployer: string | null;
}
export interface MetricPoint { t: number; memory_bytes: Num; cpu_percent: Num; restarts: Num; state: string | null; disk_bytes?: Num }
export interface Series<P> { range: string; bucket_s: number; points: number; from: Num; to: Num; data_since: Num; series: P[] }
export type Metrics = Series<MetricPoint>;
/** snapshot --range without --app: load (1 min average), cpu % of all cores, memory, disk of /var/lib/tando */
export interface HostMetricPoint {
  t: number; load: Num; cpu_percent: Num; memory_used_bytes: Num; memory_total_bytes: Num; disk_used_bytes: Num; disk_total_bytes: Num;
}
export type HostMetrics = Series<HostMetricPoint>;
export interface Incident { start: number; end: Num; check: string; cause: string | null }
export interface Health {
  uptime_24h_pct: Num; uptime_7d_pct: Num; incidents_7d: Num; p50_ms: Num; p95_ms: Num; last: string | null; last_ms: Num;
  series: { bucket_s: number; stat: string; points: { t: number; avg_ms: Num }[] };
  incidents: Incident[];
}
export interface AppDetail {
  name: string; status: AppRow; releases: Release[]; history: HistoryRow[]; metrics: Metrics | null;
  health: Health | null; database: { bytes: Num; connections: Num; connection_limit: Num } | null;
  origin?: string | null; // user@machine:path of the last deploy (deploy runs there)
}
export interface Snapshot {
  host: string; reachable: boolean; error?: string;
  address?: string | null; user?: string | null; // the registered ssh target (newer tando; never resolved)
  checked_at: number; server_version?: string | null; client_version?: string | null;
  clock_skew_s?: Num; server_now?: Num; system?: System; apps?: AppRow[]; alerts?: Alert[]; app?: AppDetail;
  host_metrics?: HostMetrics | null;
}
export interface ApiErrorBody { code: string; message: string }

export interface DoctorResult { host: string; checks: { name: string; state: string; detail: string }[]; failed: number; warnings: number }
export interface HostStatus {
  host: string;
  machine?: { os?: string; kernel?: string };
  findings?: { id: string; state: string; title: string; detail: string | null; fix: string | null }[];
}
export interface OnDemand<T> { host: string; ran_at: string; cached: boolean; next_run_s?: number; data?: T; error?: ApiErrorBody }

/** One host as the pages see it: last good data kept when a poll fails. */
export interface HostView {
  host: string;
  data: Snapshot | null;       // last good data, never blanked
  fetchedAtS: number | null;   // when `data` was read (unix s)
  error: string | null;        // why the latest read failed, one line
  reachable: boolean;          // data present and the host answered
}
