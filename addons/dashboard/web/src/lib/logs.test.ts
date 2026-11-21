import { describe, expect, it } from "vitest";
import {
  appendLines, BUFFER_MAX, filterLines, followLine, LogFollow, levelWord, matchText, msgCols, parseLine, parseLines, rowOffsets, streamQuery,
  tailQuery, textProblem, visibleRange, workerOf, workersIn, ES_CLOSED, ES_CONNECTING, type ESLike, type FollowState, type LogLine, NO_FILTERS,
} from "./logs";

const raw = (i: number, over: Record<string, unknown> = {}) => ({ time: "t", usec: 1795247000000000 + i * 250000, src: "app", unit: "tando-shop.service", priority: 6, level: "info", msg: `line ${i}`, ...over });
const line = (i: number, msg = `line ${i}`, worker: string | null = null): LogLine => ({ id: i, usec: i, t: i, level: "inf", worker, unit: "", src: "", msg });

describe("log line parsing", () => {
  it("maps priority and level words to the 3-letter words", () => {
    expect([0, 3, 4, 5, 6, 7].map((p) => levelWord(p, undefined))).toEqual(["err", "err", "wrn", "inf", "inf", "dbg"]);
    expect(levelWord(undefined, "warning")).toBe("wrn");
    expect(levelWord(undefined, "error")).toBe("err");
    expect(levelWord("3", "info")).toBe("err");
    expect(levelWord(undefined, undefined)).toBe("inf");
  });
  it("reads the worker from the unit name", () => {
    expect(workerOf("tando-shop_worker-mail.service")).toBe("mail");
    expect(workerOf("tando-shop_worker-q-2.service")).toBe("q-2");
    expect(workerOf("tando-shop.service")).toBeNull();
    expect(workerOf("tando-shop_job-nightly.service")).toBeNull();
    expect(workerOf(undefined)).toBeNull();
  });
  it("parses a CLI line and drops what is not a log line", () => {
    const l = parseLine(raw(1, { unit: "tando-shop_worker-mail.service", priority: 3 }))!;
    expect(l).toMatchObject({ level: "err", worker: "mail", msg: "line 1", t: 1795247000 });
    expect(parseLine({ foo: 1 })).toBeNull();
    expect(parseLine(null)).toBeNull();
    expect(parseLines([raw(1), "x", raw(2)])).toHaveLength(2);
  });
  it("gives every line its own id", () => { const [a, b] = parseLines([raw(1), raw(1)]); expect(a.id).not.toBe(b.id); });
});

describe("log filters", () => {
  it("builds the tail query with every filter", () => {
    expect(tailQuery("web-1", "shop", { level: "err", text: "GET /a b", worker: "mail", release: "20261117-101010" }, 200))
      .toBe("host=web-1&app=shop&n=200&level=err&grep=GET+%2Fa+b&worker=mail&release=20261117-101010");
    expect(tailQuery("web-1", "shop", NO_FILTERS)).toBe("host=web-1&app=shop&n=200");
  });
  it("leaves out a text filter tando-dash would refuse, and says why", () => {
    expect(tailQuery("h", "a", { ...NO_FILTERS, text: "-rf" })).not.toContain("grep");
    expect(textProblem("-rf")).toMatch(/cannot start/);
    expect(textProblem("a".repeat(257))).toMatch(/256/);
    expect(textProblem("a\u0001b")).toMatch(/control/);
    expect(textProblem("timeout")).toBeNull();
    expect(textProblem("")).toBeNull();
  });
  it("a follow takes level and worker only", () => {
    expect(streamQuery("h", "a", { level: "warning", text: "x", worker: "mail", release: "r" })).toBe("host=h&app=a&level=warning&worker=mail");
  });
  it("matches text case-insensitively in the page", () => {
    expect(matchText(line(1, "Connection TIMEOUT"), "timeout")).toBe(true);
    expect(filterLines([line(1, "a"), line(2, "b")], "b").map((l) => l.id)).toEqual([2]);
    expect(filterLines([line(1)], "")).toHaveLength(1);
  });
  it("lists the workers seen plus the chosen one", () => {
    expect(workersIn([line(1, "x", "mail"), line(2, "y", null), line(3, "z", "q")], "zzz")).toEqual(["mail", "q", "zzz"]);
  });
});

describe("ring buffer", () => {
  it("keeps the newest 5000 lines", () => {
    let b: LogLine[] = [];
    for (let k = 0; k < 6; k++) b = appendLines(b, Array.from({ length: 1000 }, (_, i) => line(k * 1000 + i)));
    expect(b).toHaveLength(BUFFER_MAX);
    expect(b[0].id).toBe(1000);
    expect(b.at(-1)!.id).toBe(5999);
  });
  it("returns the same array for nothing to add", () => { const b = [line(1)]; expect(appendLines(b, [])).toBe(b); });
});

describe("virtual list geometry", () => {
  const lines = [line(1, "x".repeat(10)), line(2, "y".repeat(200)), line(3, "z")];
  it("rows are 18 px, a wrapped or expanded row takes as many rows as its text needs", () => {
    expect(rowOffsets(lines, false, new Set(), 50)).toEqual([0, 18, 36, 54]);
    expect(rowOffsets(lines, true, new Set(), 50)).toEqual([0, 18, 18 + 4 * 18, 18 + 5 * 18]);
    expect(rowOffsets(lines, false, new Set([2]), 50)[2]).toBe(18 + 72);
  });
  it("draws only the rows in view plus a margin", () => {
    const many = Array.from({ length: 5000 }, (_, i) => line(i));
    const offs = rowOffsets(many, false, new Set(), 80);
    const r = visibleRange(offs, 18 * 1000, 400, 6);
    expect(r.start).toBe(994);
    expect(r.end - r.start).toBeLessThan(40);
    expect(visibleRange(offs, 0, 400, 6).start).toBe(0);
    expect(visibleRange([0], 0, 400)).toEqual({ start: 0, end: 0 });
  });
  it("columns shrink with the width and keep a floor", () => {
    expect(msgCols(1200, false)).toBeGreaterThan(msgCols(600, false));
    expect(msgCols(100, true)).toBe(20);
  });
});

// ---- follow: a fake EventSource ----
class FakeES implements ESLike {
  readyState = ES_CONNECTING; closed = false;
  private fns = new Map<string, ((e: { data?: string }) => void)[]>();
  constructor(public url: string) {}
  addEventListener(t: string, f: (e: { data?: string }) => void) { this.fns.set(t, [...(this.fns.get(t) ?? []), f]); }
  close() { this.closed = true; this.readyState = ES_CLOSED; }
  emit(t: string, data?: unknown) { for (const f of this.fns.get(t) ?? []) f({ data: data === undefined ? undefined : JSON.stringify(data) }); }
  nativeError(closed: boolean) { this.readyState = closed ? ES_CLOSED : ES_CONNECTING; for (const f of this.fns.get("error") ?? []) f({}); }
}
function rig() {
  const sources: FakeES[] = [];
  const states: FollowState[] = [];
  const batches: LogLine[][] = [];
  const frames: (() => void)[] = [];
  const env = { schedule: (f: () => void) => { frames.push(f); return frames.length; }, cancel: (h: unknown) => { frames[(h as number) - 1] = () => {}; } };
  const mk = () => new LogFollow("/api/logs/stream?host=h&app=a", (u) => { const s = new FakeES(u); sources.push(s); return s; }, { onState: (s) => states.push(s), onLines: (b) => batches.push(b) }, env);
  return { sources, states, batches, frames, mk, flush: () => { frames.splice(0).forEach((f) => f()); } };
}

describe("follow state machine", () => {
  it("connecting, then live on hello; lines are batched into one delivery per frame", () => {
    const r = rig(); const f = r.mk(); f.start();
    expect(r.states.at(-1)).toEqual({ kind: "connecting" });
    r.sources[0].emit("hello", { host: "h", app: "a", buffered: 0 });
    expect(r.states.at(-1)).toEqual({ kind: "live" });
    for (let i = 0; i < 3; i++) r.sources[0].emit("line", raw(i));
    expect(r.batches).toHaveLength(0);
    r.flush();
    expect(r.batches).toHaveLength(1);
    expect(r.batches[0].map((l) => l.msg)).toEqual(["line 0", "line 1", "line 2"]);
  });
  it("heartbeat changes nothing", () => {
    const r = rig(); const f = r.mk(); f.start();
    r.sources[0].emit("hello", {}); const n = r.states.length;
    r.sources[0].emit("heartbeat", {});
    expect(r.states).toHaveLength(n);
  });
  it("reconnecting then reconnected: stays open, back to live", () => {
    const r = rig(); const f = r.mk(); f.start();
    r.sources[0].emit("hello", {});
    r.sources[0].emit("reconnecting", { attempt: 2, retry_in_ms: 2000, message: "x" });
    expect(r.states.at(-1)).toEqual({ kind: "reconnecting", attempt: 2, retryInMs: 2000 });
    expect(followLine(r.states.at(-1)!)).toMatch(/reconnecting \(attempt 2\)/);
    r.sources[0].emit("reconnected", {});
    expect(r.states.at(-1)).toEqual({ kind: "live" });
    expect(r.sources[0].closed).toBe(false);
  });
  it("closes the source on the server's error event, with a one-line state and no reconnect", () => {
    const r = rig(); const f = r.mk(); f.start();
    r.sources[0].emit("hello", {});
    r.sources[0].emit("error", { code: "ended", message: "failed 5 times" });
    expect(r.sources[0].closed).toBe(true);
    const s = r.states.at(-1) as Extract<FollowState, { kind: "stopped" }>;
    expect(s).toMatchObject({ kind: "stopped", reason: "ended" });
    expect(s.message).not.toContain("\n");
    expect(s.message).toMatch(/Resume|resume/);
  });
  it("busy (an error with code busy) closes and says the sessions are taken", () => {
    const r = rig(); const f = r.mk(); f.start();
    r.sources[0].emit("error", { code: "busy", message: "all taken" });
    expect(r.sources[0].closed).toBe(true);
    expect(r.states.at(-1)).toMatchObject({ kind: "stopped", reason: "busy" });
    expect((r.states.at(-1) as { message: string }).message).toMatch(/sessions/);
  });
  it("closes on dropped, delivering the lines that arrived before it", () => {
    const r = rig(); const f = r.mk(); f.start();
    r.sources[0].emit("hello", {});
    r.sources[0].emit("line", raw(1));
    r.sources[0].emit("dropped", {});
    expect(r.sources[0].closed).toBe(true);
    expect(r.batches.flat().map((l) => l.msg)).toEqual(["line 1"]);
    expect(r.states.at(-1)).toMatchObject({ kind: "stopped", reason: "dropped" });
  });
  it("ignores everything after it closed", () => {
    const r = rig(); const f = r.mk(); f.start();
    r.sources[0].emit("dropped", {});
    const n = r.states.length;
    r.sources[0].emit("line", raw(9)); r.sources[0].emit("reconnected", {});
    r.flush();
    expect(r.states).toHaveLength(n);
    expect(r.batches.flat()).toHaveLength(0);
  });
  it("the browser's own error: reconnecting while it retries, stopped when it gave up", () => {
    const r = rig(); const f = r.mk(); f.start();
    r.sources[0].emit("hello", {});
    r.sources[0].nativeError(false);
    expect(r.states.at(-1)).toMatchObject({ kind: "reconnecting", attempt: 1 });
    expect(r.sources[0].closed).toBe(false);
    r.sources[0].nativeError(true);
    expect(r.states.at(-1)).toMatchObject({ kind: "stopped", reason: "lost" });
  });
  it("Resume is a new source; the old one stays closed", () => {
    const r = rig(); const f = r.mk(); f.start();
    r.sources[0].emit("dropped", {});
    const g = r.mk(); g.start();
    expect(r.sources).toHaveLength(2);
    expect(r.sources[0].closed).toBe(true);
    r.sources[1].emit("hello", {});
    expect(g.current).toEqual({ kind: "live" });
  });
  it("stop() closes the source and drops pending lines", () => {
    const r = rig(); const f = r.mk(); f.start();
    r.sources[0].emit("line", raw(1));
    f.stop();
    r.flush();
    expect(r.sources[0].closed).toBe(true);
    expect(r.batches).toHaveLength(0);
  });
  it("start twice opens one source", () => { const r = rig(); const f = r.mk(); f.start(); f.start(); expect(r.sources).toHaveLength(1); });
});

describe("no browser storage for logs", () => {
  it("the log code never touches localStorage, sessionStorage or IndexedDB", async () => {
    const { readFileSync } = await import("node:fs");
    for (const f of ["logs.ts", "../components/log-viewer.tsx"]) {
      const src = readFileSync(new URL(f, import.meta.url), "utf8");
      expect(src).not.toMatch(/localStorage|sessionStorage|indexedDB|lsSet/);
    }
  });
});
