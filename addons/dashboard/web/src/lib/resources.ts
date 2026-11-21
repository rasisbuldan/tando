import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { apiGet, qs, ApiError } from "./api";
import { Poller, isStale, type PollState } from "./poller";
import { mergeViews, toViews, type RawHost } from "./shape";
import { share } from "./share";
import type { DoctorResult, HostStatus, HostView, OnDemand, Snapshot } from "./types";

const registry = new Map<string, Poller<never>>();
export function registerPoller<T>(key: string, make: () => Poller<T>): Poller<T> {
  let p = registry.get(key) as Poller<T> | undefined;
  if (!p) { p = make(); registry.set(key, p as unknown as Poller<never>); }
  return p;
}
if (typeof document !== "undefined") {
  document.addEventListener("visibilitychange", () => registry.forEach((p) => p.visibility()));
}
const vis = (visible: boolean) => (visible ? "1" : "0");

export function overviewPoller(): Poller<HostView[]> {
  return registerPoller("overview", () => new Poller<HostView[]>(async (visible) => {
    const r = await apiGet<{ hosts: RawHost[]; next_poll_s?: number }>(`/api/overview?${qs({ visible: vis(visible) })}`);
    return { data: toViews(r.hosts), nextPollS: r.next_poll_s };
  }, mergeViews));
}

export interface SnapView { view: HostView }
export function snapshotPoller(host: string, app?: string, range?: string): Poller<HostView> {
  return registerPoller(`snap:${host}:${app ?? ""}:${range ?? ""}`, () => new Poller<HostView>(async (visible) => {
    const r = await apiGet<{ fetched_at?: string; next_poll_s?: number; data: Snapshot }>(
      `/api/snapshot?${qs({ host, app, range, visible: vis(visible) })}`);
    const [v] = toViews([{ host, ok: true, fetched_at: r.fetched_at, data: r.data }]);
    return { data: v, nextPollS: r.next_poll_s };
  }, (prev, next) => {
    // a failed read keeps what was shown; the pages see it through `error`
    if (!next.data && prev?.data) return { ...next, data: prev.data, fetchedAtS: prev.fetchedAtS, reachable: false };
    return prev ? { ...next, data: share(prev.data, next.data) } : next;
  }));
}

export function usePoller<T>(p: Poller<T>): PollState<T> {
  return useSyncExternalStore(p.subscribe, p.get);
}

/** seconds clock for "updated 12 s ago"; no ticking while the tab is hidden */
export function useNowMs(everyMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    let h: ReturnType<typeof setInterval> | null = null;
    const on = () => { setNow(Date.now()); if (h == null) h = setInterval(() => setNow(Date.now()), everyMs); };
    const off = () => { if (h != null) { clearInterval(h); h = null; } };
    const vc = () => (document.hidden ? off() : on());
    if (!document.hidden) on();
    document.addEventListener("visibilitychange", vc);
    return () => { off(); document.removeEventListener("visibilitychange", vc); };
  }, [everyMs]);
  return now;
}

export function useStale(st: PollState<unknown>): boolean {
  const now = useNowMs(5000);
  return isStale(st, now);
}

export interface Demand<T> { run: () => void; loading: boolean; result: OnDemand<T> | null; error: ApiError | null; ranAtMs: number | null }
/** doctor / host status: on demand only, never polled (tando-dash allows one run a minute per host) */
export function useDemand<T>(kind: "doctor" | "hoststatus", host: string): Demand<T> {
  const [st, setSt] = useState<{ loading: boolean; result: OnDemand<T> | null; error: ApiError | null; ranAtMs: number | null }>(
    { loading: false, result: null, error: null, ranAtMs: null });
  const host0 = useRef(host);
  useEffect(() => { if (host0.current !== host) { host0.current = host; setSt({ loading: false, result: null, error: null, ranAtMs: null }); } }, [host]);
  const run = useCallback(() => {
    setSt((s) => ({ ...s, loading: true, error: null }));
    apiGet<OnDemand<T>>(`/api/${kind}?${qs({ host })}`)
      .then((r) => setSt({ loading: false, result: r, error: r.error ? new ApiError(r.error.code, r.error.message) : null, ranAtMs: Date.now() }))
      .catch((e: ApiError) => setSt((s) => ({ ...s, loading: false, error: e })));
  }, [kind, host]);
  return { run, ...st };
}
export type { DoctorResult, HostStatus };
export function refreshAll() { registry.forEach((p) => p.refresh()); if (typeof window !== "undefined") window.dispatchEvent(new Event("tando:refresh")); }
export const REFRESH_EVENT = "tando:refresh";
