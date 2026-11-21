import { describe, expect, it } from "vitest";
import { fixture } from "./fixtures";
import type { Snapshot } from "./types";
import {
  appKind, appRows, chartDomain, dataSince, defaultOrder, describe as describeSeries, headroom, keepOrder, mergeViews, needsAttention,
  nextSort, niceMax, phases, restartsTotal, rowKey, skewNote, sortRows, stateWithReason, toPoints, toViews, uptimeCells, type RawHost,
} from "./shape";

const snap = fixture<Snapshot>("snapshot");
const snapApp = fixture<Snapshot>("snapshot-app");
const raw = (over: Partial<RawHost> = {}): RawHost => ({ host: "web-1", ok: true, fetched_at: "2026-11-21T14:02:00Z", data: snap, ...over });

describe("metrics: gaps and restarts", () => {
  const m = snapApp.app!.metrics!;
  it("keeps null buckets as null, never zero or interpolated", () => {
    const pts = toPoints(m.series, "memory_bytes");
    expect(pts).toHaveLength(m.series.length);
    expect(pts.filter((p) => p.v === null).length).toBe(m.series.filter((p) => p.memory_bytes === null).length);
    expect(pts.some((p) => p.v === 0)).toBe(false);
    const i = pts.findIndex((p, k) => p.v === null && pts[k - 1]?.v != null);
    expect(i).toBeGreaterThan(0); // a gap in the middle stays a gap between two values
    expect(pts[i + 1].v).not.toBeNull();
  });
  it("describes a series: gaps, first, last, min, max", () => {
    const g = describeSeries(toPoints(m.series, "memory_bytes"));
    expect(g.last).toBe(104857600);
    expect(g.first).toBe(100000000);
    expect(g.gaps).toBeGreaterThan(100);
    expect(g.min).toBe(100000000);
  });
  it("shows the server's per-bucket restart values and sums them (null counts as nothing)", () => {
    const pts = toPoints(m.series, "restarts");
    expect(restartsTotal(pts)).toBe(2);
    expect(restartsTotal([{ t: 1, v: null }])).toBe(0);
  });
  it("data since: only when retained data starts after the domain start", () => {
    const d = chartDomain("24h", snapApp.server_now, m);
    expect(d.to - d.from).toBe(86400);
    expect(dataSince(m, d)).toBe(m.data_since);
    expect(dataSince({ ...m, data_since: d.from - 1000 }, d)).toBeNull();
    expect(dataSince({ ...m, data_since: null }, d)).toBeNull();
    expect(dataSince(null, d)).toBeNull();
  });
  it("chart domain uses the server clock", () => {
    expect(chartDomain("1h", 10000, null)).toEqual({ from: 6400, to: 10000 });
  });
  it("niceMax rounds up", () => { expect(niceMax(3.4)).toBe(5); expect(niceMax(0)).toBe(1); expect(niceMax(180)).toBe(200); });
  it("uptime strip marks incidents, gaps and ok", () => {
    const cells = uptimeCells(m, snapApp.app!.health!.incidents, m.to!);
    expect(cells.some((c) => c.kind === "fail")).toBe(true);
    expect(cells.some((c) => c.kind === "none")).toBe(true);
    expect(cells.some((c) => c.kind === "ok")).toBe(true);
  });
});

describe("clock skew note", () => {
  it("only over 30 s", () => {
    expect(skewNote(3)).toBeNull();
    expect(skewNote(30)).toBeNull();
    expect(skewNote(42)).toBe("clock 42 s ahead");
    expect(skewNote(-95)).toBe("clock 95 s behind");
    expect(skewNote(null)).toBeNull();
  });
});

describe("state words come from state_reason", () => {
  it("maps each reason", () => {
    const k = (r: string) => appKind({ state_reason: r, state: null });
    expect(k("running")).toEqual({ kind: "ok", word: "running" });
    expect(k("down").kind).toBe("fail");
    expect(k("failed").kind).toBe("fail");
    expect(k("stopped").kind).toBe("neutral");
    expect(k("deploying").kind).toBe("info");
    expect(k("not_deployed").word).toBe("never deployed");
    expect(k("weird").kind).toBe("stale");
  });
  it("adds the firing alert's detail to down", () => {
    const api = snap.apps!.find((a) => a.app === "api")!;
    expect(stateWithReason(api, snap.alerts)).toBe("down · exited");
    expect(stateWithReason(snap.apps![0], snap.alerts)).toBe("running");
  });
});

describe("headroom", () => {
  it("sums memory caps against RAM", () => {
    const h = headroom(snap.apps, snap.system!.memory_total_bytes)!;
    expect(h.capBytes).toBe(268435456);
    expect(h.pct).toBeCloseTo(13.1, 0);
    expect(headroom([], 1)).toBeNull();
    expect(headroom(snap.apps, null)).toBeNull();
  });
});

describe("host views never blank a host", () => {
  it("keeps the last data when a poll fails and marks it unreachable", () => {
    const first = mergeViews(null, toViews([raw()]));
    expect(first[0].reachable).toBe(true);
    const second = mergeViews(first, toViews([{ host: "web-1", ok: false, error: { code: "timeout", message: "ssh timed out" } }]));
    expect(second[0].data).toBe(first[0].data);
    expect(second[0].reachable).toBe(false);
    expect(second[0].error).toBe("ssh timed out");
    expect(second[0].fetchedAtS).toBe(first[0].fetchedAtS);
  });
  it("treats a reachable:false snapshot as a failure and keeps old data", () => {
    const first = mergeViews(null, toViews([raw()]));
    const down = mergeViews(first, toViews([raw({ data: fixture("snapshot-unreachable") })]));
    expect(down[0].data).toBe(first[0].data);
    expect(down[0].error).toBe("connection refused");
  });
  it("a host that never answered has no data and says why", () => {
    const v = mergeViews(null, toViews([raw({ data: fixture("snapshot-unreachable") })]));
    expect(v[0].data).toBeNull();
    expect(v[0].reachable).toBe(false);
  });
  it("shares unchanged objects between polls", () => {
    const a = mergeViews(null, toViews([raw()]));
    const b = mergeViews(a, toViews([raw({ data: JSON.parse(JSON.stringify(snap)) })]));
    expect(b).toBe(a);
  });
  it("orders hosts by name", () => {
    const v = mergeViews(null, toViews([raw({ host: "web-2" }), raw({ host: "web-1" })]));
    expect(v.map((h) => h.host)).toEqual(["web-1", "web-2"]);
  });
});

describe("needs attention", () => {
  const hosts = mergeViews(null, toViews([raw(), { host: "web-2", ok: false, error: { code: "x", message: "connection refused" } }]));
  it("lists firing first, then pending, includes unreachable hosts, one row per problem", () => {
    const a = needsAttention(hosts);
    expect(a.map((x) => x.word)).toEqual(["firing", "not answering", "pending"]);
    expect(a[0]).toMatchObject({ host: "web-1", app: "api", what: "down · exited" });
    expect(a.filter((x) => x.app === "api")).toHaveLength(1); // the down app is not listed twice
    expect(a[2].app).toBeNull(); // host-level disk alert
  });
  it("adds a down app that has no alert yet", () => {
    const s = JSON.parse(JSON.stringify(snap)) as Snapshot;
    s.alerts = [];
    const a = needsAttention(mergeViews(null, toViews([raw({ data: s })])));
    expect(a).toHaveLength(1);
    expect(a[0]).toMatchObject({ app: "api", word: "down" });
  });
  it("is empty when all is well", () => {
    const s = { ...snap, alerts: [], apps: snap.apps!.filter((a) => a.state_reason === "running") };
    expect(needsAttention(mergeViews(null, toViews([raw({ data: s })])))).toEqual([]);
  });
});

describe("apps table sort", () => {
  const rows = appRows(mergeViews(null, toViews([raw()])));
  it("default: attention first (fail, info, ok, neutral), then name", () => {
    expect(defaultOrder(rows).map((r) => r.app)).toEqual(["api", "fresh", "shop", "docs", "jobs"]);
  });
  it("stale host rows sort after fail and before ok", () => {
    const mixed = [...rows.filter((r) => r.app === "shop"), { ...rows.find((r) => r.app === "docs")!, stale: true }];
    expect(defaultOrder(mixed).map((r) => r.app)).toEqual(["docs", "shop"]);
  });
  it("sorts by memory desc with missing values last in both directions", () => {
    expect(sortRows(rows, { key: "memory", dir: "desc" })[0].app).toBe("shop");
    expect(sortRows(rows, { key: "memory", dir: "asc" })[0].app).toBe("shop"); // only one value; others are missing
    expect(sortRows(rows, { key: "cpu", dir: "desc" }).slice(1).map((r) => r.app)).toEqual(["api", "docs", "fresh", "jobs"]);
  });
  it("sorts by restarts, name, last deploy", () => {
    expect(sortRows(rows, { key: "restarts", dir: "desc" })[0].app).toBe("api");
    expect(sortRows(rows, { key: "app", dir: "asc" }).map((r) => r.app)).toEqual(["api", "docs", "fresh", "jobs", "shop"]);
    expect(sortRows(rows, { key: "deployed", dir: "desc" })[0].app).toBe("shop");
  });
  it("header click: new key starts desc (text keys asc), same key toggles", () => {
    expect(nextSort(null, "memory")).toEqual({ key: "memory", dir: "desc" });
    expect(nextSort({ key: "memory", dir: "desc" }, "memory")).toEqual({ key: "memory", dir: "asc" });
    expect(nextSort(null, "app")).toEqual({ key: "app", dir: "asc" });
  });
  it("keeps rows in place on a poll that changes values (re-sort only on user action)", () => {
    const order = sortRows(rows, null).map(rowKey);
    const changed = rows.map((r) => (r.app === "shop" ? { ...r, memory_bytes: 1, state_reason: "down" } : r)).reverse();
    expect(keepOrder(order, changed).map(rowKey)).toEqual(order);
    const extra = [...rows, { ...rows[0], app: "zeta" }];
    expect(keepOrder(order, extra).at(-1)!.app).toBe("zeta");
  });
});

describe("deploy phases", () => {
  const h = snapApp.app!.history;
  it("upload includes the copy; null phases are left out; failed deploys stop where they failed", () => {
    expect(phases(h[0]).map((p) => p.label)).toEqual(["build", "upload", "release command", "preflight", "switch", "verify"]);
    expect(phases(h[0])[1].s).toBeCloseTo(5.2);
    expect(phases(h[1]).map((p) => p.label)).toEqual(["switch", "verify"]);
    expect(phases(h[2]).map((p) => p.label)).toEqual(["build", "upload", "preflight"]);
  });
  it("history carries the deployer", () => { expect(h.map((x) => x.deployer)).toEqual(["ci-bot", "alice", null]); });
});
