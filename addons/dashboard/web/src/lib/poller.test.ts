import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, apiGet, sessionStore, type Fetcher } from "./api";
import { backoffMs, isStale, Poller, type PollerEnv } from "./poller";
import { share } from "./share";

// a fake clock: timers run only when the test advances it
function fakeEnv() {
  let now = 1_000_000, id = 0, hidden = false;
  const timers = new Map<number, { at: number; f: () => void }>();
  const env: PollerEnv = {
    now: () => now, rand: () => 0.5, hidden: () => hidden,
    setTimeout: (f, ms) => { timers.set(++id, { at: now + ms, f }); return id; },
    clearTimeout: (h) => { timers.delete(h as number); },
  };
  const flush = () => new Promise<void>((r) => setImmediate(r));
  return {
    env, timers,
    async advance(ms: number) {
      const to = now + ms;
      for (;;) {
        const next = [...timers.entries()].filter(([, t]) => t.at <= to).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        timers.delete(next[0]); now = next[1].at; next[1].f(); await flush();
      }
      now = to;
    },
    flush, setHidden(h: boolean) { hidden = h; }, get now() { return now; },
  };
}

describe("backoff", () => {
  it("1, 2, 4, 8 s then 30 s, +-20% jitter", () => {
    expect([1, 2, 3, 4, 5, 6].map((n) => backoffMs(n, () => 0.5))).toEqual([1000, 2000, 4000, 8000, 30000, 30000]);
    expect(backoffMs(1, () => 0)).toBe(800); expect(backoffMs(1, () => 1 - 1e-9)).toBe(1200);
    expect(backoffMs(9, () => 0)).toBe(24000); expect(backoffMs(9, () => 1 - 1e-9)).toBe(36000);
  });
});

describe("Poller (fake clock)", () => {
  let c: ReturnType<typeof fakeEnv>;
  beforeEach(() => { c = fakeEnv(); });
  const mk = (fetchFn: (v: boolean) => Promise<{ data: number; nextPollS?: number }>) => new Poller<number>(fetchFn, undefined, c.env);

  it("fetches on subscribe, then every next_poll_s from the answer", async () => {
    let n = 0;
    const calls: boolean[] = [];
    const p = mk(async (v) => { calls.push(v); return { data: ++n, nextPollS: n === 1 ? 15 : 60 }; });
    p.subscribe(() => {});
    await c.flush();
    expect(p.get().data).toBe(1);
    await c.advance(14_999); expect(n).toBe(1);
    await c.advance(2); expect(n).toBe(2);           // 15 s
    await c.advance(59_000); expect(n).toBe(2);
    await c.advance(2_000); expect(n).toBe(3);        // then 60 s: the server said so
    expect(calls.every((v) => v === true)).toBe(true); // visible=1
  });

  it("zero polls while hidden; fetches at once when the tab returns after the interval; visible=0 flag", async () => {
    let n = 0; const vis: boolean[] = [];
    const p = mk(async (v) => { vis.push(v); return { data: ++n, nextPollS: 15 }; });
    p.subscribe(() => {}); await c.flush();
    c.setHidden(true); p.visibility();
    await c.advance(10 * 60_000);
    expect(n).toBe(1);
    expect(c.timers.size).toBe(0);
    c.setHidden(false); p.visibility(); await c.flush();
    expect(n).toBe(2);
    expect(vis).toEqual([true, true]);
  });

  it("a hidden poll that was already scheduled does not fire when the tab hides", async () => {
    let n = 0;
    const p = mk(async () => ({ data: ++n, nextPollS: 15 }));
    p.subscribe(() => {}); await c.flush();
    await c.advance(5_000); c.setHidden(true); p.visibility();
    await c.advance(60_000);
    expect(n).toBe(1);
  });

  it("retries a failure after 1, 2, 4, 8 s and then 30 s; keeps the last good data", async () => {
    let n = 0; let fail = false;
    const p = mk(async () => { n++; if (fail) throw new ApiError("timeout", "slow"); return { data: n, nextPollS: 15 }; });
    p.subscribe(() => {}); await c.flush();
    fail = true;
    await c.advance(15_000); expect(n).toBe(2);
    expect(p.get().error?.code).toBe("timeout");
    expect(p.get().data).toBe(1); // never blanked
    const t0 = n; const gaps: number[] = []; let last = c.now;
    for (let i = 0; i < 6; i++) {
      const before = n;
      while (n === before) { await c.advance(500); }
      gaps.push(Math.round((c.now - last) / 500) * 500); last = c.now;
    }
    expect(n).toBeGreaterThan(t0);
    expect(gaps).toEqual([1000, 2000, 4000, 8000, 30000, 30000]);
    fail = false;
    await c.advance(30_000);
    expect(p.get().error).toBeNull(); expect(p.get().failures).toBe(0);
    expect(p.get().data).toBe(n);
  });

  it("401 session stops polling for good", async () => {
    let n = 0;
    const p = mk(async () => { n++; throw new ApiError("session", "Session ended."); });
    p.subscribe(() => {}); await c.flush();
    await c.advance(10 * 60_000);
    expect(n).toBe(1); expect(p.get().stopped).toBe(true);
  });

  it("unsubscribing stops the timer; one request in flight at a time", async () => {
    let n = 0; let release: (() => void) | undefined;
    const p = mk(() => new Promise((res) => { n++; release = () => res({ data: n }); }));
    const un = p.subscribe(() => {});
    p.refresh(); p.refresh();
    expect(n).toBe(1);
    release!(); await c.flush();
    un();
    await c.advance(120_000);
    expect(n).toBe(1);
  });
});

describe("stale", () => {
  const base = { data: 1, error: null, pollS: 15, lastOkMs: 0 };
  it("never before data", () => { expect(isStale({ ...base, data: null, lastOkMs: null }, 1e9)).toBe(false); });
  it("stale after two intervals (30 s visible)", () => { expect(isStale(base, 29_999)).toBe(false); expect(isStale(base, 30_001)).toBe(true); });
  it("with a failed read: stale after one interval (the retry had its chance)", () => {
    const e = { ...base, error: new ApiError("x", "y") };
    expect(isStale(e, 14_000)).toBe(false); expect(isStale(e, 16_000)).toBe(true);
  });
  it("follows next_poll_s: 60 s polls are stale after 120 s", () => { expect(isStale({ ...base, pollS: 60 }, 100_000)).toBe(false); expect(isStale({ ...base, pollS: 60 }, 121_000)).toBe(true); });
});

describe("401 session -> the session screen", () => {
  beforeEach(() => sessionStore.reset());
  const res = (status: number, body: unknown) => ({ ok: status < 400, status, json: async () => body });
  it("code session ends the session", async () => {
    const f: Fetcher = async () => res(401, { error: { code: "session", message: "x" } });
    await expect(apiGet("/api/overview", f)).rejects.toMatchObject({ code: "session" });
    expect(sessionStore.get()).toBe(true);
  });
  it("another error does not", async () => {
    const f: Fetcher = async () => res(500, { error: { code: "exec", message: "tando failed" } });
    await expect(apiGet("/api/overview", f)).rejects.toMatchObject({ code: "exec", message: "tando failed" });
    expect(sessionStore.get()).toBe(false);
  });
  it("network failure and timeout give a fact and a next step", async () => {
    await expect(apiGet("/x", async () => { throw new TypeError("fetch failed"); })).rejects.toMatchObject({ code: "network" });
    vi.useFakeTimers();
    const p = apiGet("/x", (_u, init) => new Promise((_r, rej) => init.signal.addEventListener("abort", () => rej(new Error("abort")))), 15000);
    const assertion = expect(p).rejects.toMatchObject({ code: "timeout" });
    await vi.advanceTimersByTimeAsync(15001);
    await assertion;
    vi.useRealTimers();
  });
  it("notifies subscribers", () => { let n = 0; const un = sessionStore.subscribe(() => n++); sessionStore.end(); sessionStore.end(); un(); expect(n).toBe(1); });
});

describe("share", () => {
  it("keeps the previous object when nothing changed, new ones where it did", () => {
    const a = { x: [1, { y: 2 }], z: { k: 1 } };
    const b = share(a, { x: [1, { y: 2 }], z: { k: 2 } });
    expect(b.x).toBe(a.x); expect(b.z).not.toBe(a.z);
    expect(share(a, JSON.parse(JSON.stringify(a)))).toBe(a);
  });
});
