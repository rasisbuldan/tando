// Polling with the tab's visibility, tando-dash's next_poll_s, retry with backoff and jitter,
// and the last good data kept on failure (DESIGN sections 7 and 12). No React in here: tested
// with a fake clock.
import { ApiError } from "./api";

const RETRY_S = [1, 2, 4, 8];
const RETRY_CAP_S = 30;
export const DEFAULT_POLL_S = 15;

/** 1 s, 2 s, 4 s, 8 s, then every 30 s; each +-20% jitter. `attempt` counts from 1. rand in [0,1). */
export function backoffMs(attempt: number, rand: () => number): number {
  const base = attempt <= RETRY_S.length ? RETRY_S[attempt - 1] : RETRY_CAP_S;
  return Math.round(base * 1000 * (0.8 + 0.4 * rand()));
}

export interface PollResult<T> { data: T; nextPollS?: number; fetchedAtS?: number }
export interface PollState<T> {
  data: T | null;
  fetchedAtS: number | null; // when the data was read (server's fetched_at, else the receipt)
  lastOkMs: number | null;   // client clock at the last success
  pollS: number;
  error: ApiError | null;    // the latest failure; cleared by the next success
  failures: number;
  loading: boolean;          // a request is in flight
  stopped: boolean;          // session ended: nothing more is fetched
}

export interface PollerEnv {
  now: () => number; // ms
  rand: () => number;
  hidden: () => boolean;
  setTimeout: (f: () => void, ms: number) => unknown;
  clearTimeout: (h: unknown) => void;
}
export const realEnv: PollerEnv = {
  now: () => Date.now(), rand: Math.random,
  hidden: () => typeof document !== "undefined" && document.hidden,
  setTimeout: (f, ms) => setTimeout(f, ms), clearTimeout: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
};

export class Poller<T> {
  private st: PollState<T>;
  private subs = new Set<() => void>();
  private timer: unknown = null;
  private inflight = false;
  private running = false;
  private seq = 0;

  constructor(
    private fetchFn: (visible: boolean) => Promise<PollResult<T>>,
    private merge: (prev: T | null, next: T) => T = (_p, n) => n,
    private env: PollerEnv = realEnv,
  ) {
    this.st = { data: null, fetchedAtS: null, lastOkMs: null, pollS: DEFAULT_POLL_S, error: null, failures: 0, loading: false, stopped: false };
  }

  get = (): PollState<T> => this.st;
  subscribe = (f: () => void): (() => void) => {
    this.subs.add(f);
    if (this.subs.size === 1) this.start();
    return () => { this.subs.delete(f); if (this.subs.size === 0) this.stop(); };
  };

  private set(p: Partial<PollState<T>>) { this.st = { ...this.st, ...p }; this.subs.forEach((f) => f()); }

  private start() {
    this.running = true;
    const age = this.st.lastOkMs == null ? Infinity : this.env.now() - this.st.lastOkMs;
    if (age >= this.st.pollS * 1000) void this.run(); else this.schedule(this.st.pollS * 1000 - age);
  }
  private stop() { this.running = false; this.seq++; this.clear(); }
  private clear() { if (this.timer != null) { this.env.clearTimeout(this.timer); this.timer = null; } }
  private schedule(ms: number) {
    this.clear();
    if (!this.running || this.st.stopped || this.env.hidden()) return; // hidden tab: zero polls
    this.timer = this.env.setTimeout(() => { this.timer = null; void this.run(); }, ms);
  }

  /** the tab became visible or hidden */
  visibility() {
    if (!this.running) return;
    if (this.env.hidden()) { this.clear(); return; }
    const age = this.st.lastOkMs == null ? Infinity : this.env.now() - this.st.lastOkMs;
    if (!this.inflight && age >= this.st.pollS * 1000) void this.run();
    else if (!this.inflight) this.schedule(this.st.failures > 0 ? backoffMs(this.st.failures, this.env.rand) : this.st.pollS * 1000 - age);
  }

  /** refresh now (button, `r`, Retry) */
  refresh() { if (this.running && !this.inflight && !this.st.stopped) { this.clear(); void this.run(); } }

  private async run() {
    if (this.inflight || this.st.stopped) return;
    this.inflight = true;
    const seq = this.seq;
    this.set({ loading: true });
    try {
      const r = await this.fetchFn(!this.env.hidden());
      if (seq !== this.seq) return;
      const data = this.merge(this.st.data, r.data);
      const nowMs = this.env.now();
      this.set({
        data, fetchedAtS: r.fetchedAtS ?? Math.floor(nowMs / 1000), lastOkMs: nowMs,
        pollS: r.nextPollS && r.nextPollS > 0 ? r.nextPollS : DEFAULT_POLL_S, error: null, failures: 0, loading: false,
      });
      this.schedule(this.st.pollS * 1000);
    } catch (e) {
      if (seq !== this.seq) return;
      const err = e instanceof ApiError ? e : new ApiError("error", e instanceof Error ? e.message : "Request failed.");
      if (err.code === "session") { this.set({ error: err, loading: false, stopped: true }); return; }
      const failures = this.st.failures + 1;
      this.set({ error: err, failures, loading: false }); // data stays
      this.schedule(backoffMs(failures, this.env.rand));
    } finally { this.inflight = false; }
  }
}

/** Stale: the last success is older than two poll intervals (30 s at the visible rate), or the
 *  latest read failed while data is on screen. Never stale before the first success. */
export function isStale(st: Pick<PollState<unknown>, "lastOkMs" | "pollS" | "error" | "data">, nowMs: number): boolean {
  if (st.data == null || st.lastOkMs == null) return false;
  if (st.error) return nowMs - st.lastOkMs > st.pollS * 1000; // grace for one retry
  return nowMs - st.lastOkMs > 2 * st.pollS * 1000;
}
