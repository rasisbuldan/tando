// Reads beyond the snapshot: jobs, requests, errors, env names and log, alerts with history.
// tando-dash answers these (see the NOTE in the M5 report for the endpoints it needs); until it
// does, a 404 shows one line per section and the rest of the page keeps working.
import { apiGet, qs, ApiError } from "./api";
import { Poller } from "./poller";
import { share } from "./share";
import type { AlertsData, EnvLog, EnvNames, ErrorsData, JobsData, Requests } from "./pages";
import type { HostView, Snapshot } from "./types";
import { registerPoller } from "./resources";

export type ExtraKind = "jobs" | "requests" | "errors" | "envnames" | "envlog" | "alerts";
export interface ExtraTypes { jobs: JobsData; requests: Requests; errors: ErrorsData; envnames: EnvNames; envlog: EnvLog; alerts: AlertsData }
interface Envelope<T> { data?: T; ran_at?: string; next_poll_s?: number; error?: { code: string; message: string } }

/** the answer's one-line error: a missing endpoint says what to do */
export function extraError(e: ApiError | null, what: string): string | null {
  if (!e) return null;
  if (e.code === "http_404" || e.code === "not_found" || e.code === "bad_request") return `Could not read ${what}: this tando-dash cannot read it yet. Update with \`tando addon install dashboard\`.`;
  return `Could not read ${what}: ${e.message}`;
}

const POLL_S = 60; // the server caches these; they change slowly

function get<T>(kind: ExtraKind, p: Record<string, string | undefined>) {
  return async (): Promise<{ data: T; nextPollS: number }> => {
    const r = await apiGet<Envelope<T>>(`/api/${kind}?${qs(p)}`);
    if (r.error) throw new ApiError(r.error.code, r.error.message);
    if (r.data == null) throw new ApiError("bad_response", "tando-dash sent no data.");
    return { data: r.data, nextPollS: r.next_poll_s ?? POLL_S };
  };
}

export function extraPoller<K extends ExtraKind>(kind: K, host: string, app: string | undefined, range?: string): Poller<ExtraTypes[K]> {
  return registerPoller(`x:${kind}:${host}:${app ?? ""}:${range ?? ""}`, () => {
    const f = get<ExtraTypes[K]>(kind, { host, app, range });
    return new Poller<ExtraTypes[K]>(() => f(), (prev, next) => share(prev, next));
  });
}

/** all hosts' alerts, history and notifiers in one poll; a host that fails is listed, the others show */
export interface AllAlerts { byHost: AlertsData[]; failed: { host: string; message: string }[] }
export function allAlertsPoller(hosts: string[]): Poller<AllAlerts> {
  return registerPoller(`x:alerts-all:${hosts.join(",")}`, () => new Poller<AllAlerts>(async () => {
    const rs = await Promise.allSettled(hosts.map((h) => get<AlertsData>("alerts", { host: h })()));
    const byHost: AlertsData[] = [], failed: AllAlerts["failed"] = [];
    rs.forEach((r, i) => { if (r.status === "fulfilled") byHost.push(r.value.data); else failed.push({ host: hosts[i], message: r.reason instanceof Error ? r.reason.message : "not answering" }); });
    if (byHost.length === 0 && failed.length) throw new ApiError("error", extraError(rs[0].status === "rejected" && rs[0].reason instanceof ApiError ? rs[0].reason : null, "alerts") ?? failed[0].message);
    return { data: { byHost, failed }, nextPollS: POLL_S };
  }, (prev, next) => share(prev, next)));
}

/** every app's snapshot history (the deploy timeline); one read per (host, app), from the cache the Overview fills */
export interface AllHistory { rows: import("./pages").TimelineRow[]; failed: string[] }
export function allHistoryPoller(pairs: { host: string; app: string }[]): Poller<AllHistory> {
  return registerPoller(`x:history-all:${pairs.map((p) => `${p.host}/${p.app}`).join(",")}`, () => new Poller<AllHistory>(async () => {
    const rs = await Promise.allSettled(pairs.map((p) => apiGet<{ data: Snapshot }>(`/api/snapshot?${qs({ host: p.host, app: p.app, range: "1h", visible: "1" })}`)));
    const rows: AllHistory["rows"] = [], failed: string[] = [];
    rs.forEach((r, i) => {
      if (r.status === "fulfilled") (r.value.data?.app?.history ?? []).forEach((h) => rows.push({ ...h, host: pairs[i].host }));
      else failed.push(`${pairs[i].host}/${pairs[i].app}`);
    });
    return { data: { rows, failed }, nextPollS: 30 };
  }, (prev, next) => share(prev, next)));
}

export function reachableApps(hosts: HostView[] | null): { host: string; app: string }[] {
  return (hosts ?? []).filter((h) => h.reachable).flatMap((h) => (h.data?.apps ?? []).map((a) => ({ host: h.host, app: a.app })));
}
