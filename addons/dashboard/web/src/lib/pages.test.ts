import { describe, expect, it } from "vitest";
import { fixture } from "./fixtures";
import type { Snapshot, Release, HistoryRow } from "./types";
import {
  alertRows, alertSpans, changesBetween, classShares, cleanNote, defaultPair, envAction, envKeys, envRows, envTime, errorGroups, jobRuns, jobsOrder,
  jobState, perMinute, runBars, slowestPaths, splitPath, timeline, timelineKey, timelineOptions,
  type AlertsData, type EnvLog, type ErrorsData, type JobsData, type Requests,
} from "./pages";

const requests = fixture<Requests>("requests");
const errors = fixture<ErrorsData>("errors");
const jobs = fixture<JobsData>("jobs");
const envLog = fixture<EnvLog>("env-log");
const envNames = fixture<{ names: string[] }>("env-ls");
const alerts = fixture<AlertsData>("alerts");
const snapApp = fixture<Snapshot>("snapshot-app");

describe("traffic", () => {
  it("status-class shares add up to 100 and leave out empty classes", () => {
    const s = classShares(requests);
    expect(s.map((x) => x.cls)).toEqual(["2xx", "3xx", "4xx", "5xx"]);
    expect(s.reduce((a, b) => a + b.pct, 0)).toBeCloseTo(100);
    expect(s[0]).toMatchObject({ n: 100 });
    expect(classShares({ status_classes: { "2xx": 0 }, total: 0 })).toEqual([]);
  });
  it("requests per minute: the total and the 5xx are what the series has", () => {
    const pts = perMinute(requests);
    expect(pts).toHaveLength(requests.series.length);
    expect(pts[0]).toEqual({ t: requests.series[0].t, v: 8, w: 0 });
    expect(pts.at(-1)!.w).toBe(3);
    expect(perMinute({ bucket_s: 30, series: [{ t: 1, requests: 5, c5xx: 1 }] })[0]).toEqual({ t: 1, v: 10, w: 2 }); // per minute, not per bucket
  });
  it("slowest paths by mean time; the method is split off the path", () => {
    const p = slowestPaths(requests);
    expect(p.map((x) => x.path)).toEqual(["GET /api/items/:n", "POST /cart \"x\"", "GET /"]);
    expect(splitPath(p[0].path)).toEqual({ method: "GET", path: "/api/items/:n" });
    expect(splitPath("/plain")).toEqual({ method: null, path: "/plain" });
    expect(slowestPaths(requests, 1)).toHaveLength(1);
  });
  it("error groups: newest last seen first, with the per-hour values for the 7-day sparkline", () => {
    const g = errorGroups(errors);
    expect(g[0].last_seen!).toBeGreaterThanOrEqual(g[1].last_seen!);
    expect(g[0].spark).toHaveLength(g[0].series.length);
    expect(g.find((x) => x.id === "0a1b2c3d")!.spark.reduce((a: number, b) => a + (b ?? 0), 0)).toBe(3);
    expect(errorGroups(null)).toEqual([]);
  });
});

describe("jobs", () => {
  it("shows the last run as the one bar when the data has no run list", () => {
    const [nightly] = jobs.jobs;
    expect(jobRuns(nightly)).toEqual([{ at: nightly.last_run, result: "success", duration_s: 12.5 }]);
    const bars = runBars(jobRuns(nightly));
    expect(bars).toHaveLength(1);
    expect(bars[0]).toMatchObject({ result: "ok", h: 1 });
  });
  it("uses `runs` when present: newest 20, bars oldest first, tall by duration, coloured by result", () => {
    const runs = Array.from({ length: 25 }, (_, i) => ({ at: 1000 + i, result: i % 5 === 0 ? "failed" : "success", duration_s: i + 1 }));
    const j = { ...jobs.jobs[0], runs };
    expect(jobRuns(j)).toHaveLength(20);
    expect(jobRuns(j)[0].at).toBe(1024);
    const bars = runBars(jobRuns(j));
    expect(bars[0].at).toBeLessThan(bars.at(-1)!.at);
    expect(bars.at(-1)!.h).toBe(1);
    expect(bars.find((b) => b.at === 1020)!.result).toBe("fail");
    expect(runBars([{ at: 1, result: "success", duration_s: null }])[0].h).toBeGreaterThan(0);
  });
  it("a job that never ran has no bars; paused jobs sort last; state words", () => {
    expect(jobRuns({ ...jobs.jobs[0], last_run: null, result: null, duration_s: null })).toEqual([]);
    expect(jobsOrder([jobs.jobs[1], jobs.jobs[0]]).map((j) => j.name)).toEqual(["nightly", "sync"]);
    expect(jobState("paused")).toEqual({ kind: "neutral", word: "paused" });
    expect(jobState("on").word).toBe("on");
  });
});

describe("env", () => {
  it("parses the change-log time", () => {
    expect(envTime("2026-11-21 06:42 UTC")).toBe(Date.UTC(2026, 10, 21, 6, 42) / 1000);
    expect(envTime("nonsense")).toBeNull();
  });
  it("key names with when they last changed and the note of that change", () => {
    const rows = envRows(envNames.names, envLog.entries);
    expect(rows.map((r) => r.key)).toEqual(["DATABASE_URL", "PUBLIC_BASE_URL", "SESSION_SECRET"]);
    const s = rows.find((r) => r.key === "SESSION_SECRET")!;
    expect(s).toMatchObject({ by: "alice", note: "rotate the session key", changedAt: envTime("2026-11-21 06:42 UTC") });
    expect(rows.find((r) => r.key === "DATABASE_URL")!.note).toBeNull(); // "-" is no note
    expect(envRows(["X"], [])[0]).toEqual({ key: "X", changedAt: null, note: null, by: null });
  });
  it("never carries a value: a row has names and metadata only", () => {
    expect(Object.keys(envRows(envNames.names, envLog.entries)[0]).sort()).toEqual(["by", "changedAt", "key", "note"]);
  });
  it("actions and keys of a log entry", () => {
    expect(envAction(envLog.entries[0])).toBe("set");
    expect(envAction(envLog.entries[1])).toBe("import");
    expect(envAction({ ...envLog.entries[0], changed: [], removed: ["OLD"] })).toBe("unset");
    expect(envKeys(envLog.entries[1])).toEqual([{ key: "DATABASE_URL", op: "added" }, { key: "PUBLIC_BASE_URL", op: "added" }]);
    expect(cleanNote("-")).toBeNull(); expect(cleanNote("x")).toBe("x");
  });
});

describe("what changed", () => {
  const rel = (id: string, at: number, current = false): Release => ({ id, deployed_at: at, status: "verified", current, last_good: false });
  const releases = [rel("r3", 3000, true), rel("r2", 2000), rel("r1", 1000)];
  const h = (release: string, at: number, note: string | null, kind = "deploy"): HistoryRow => ({ at, app: "shop", release, kind, result: "verified", total_s: 10, build_s: 1, upload_s: 1, copy_s: null, release_s: null, preflight_s: 1, switch_s: 1, verify_s: 1, note, deployer: "a" });
  const history = [h("r3", 3001, "add search"), h("r2", 2001, "fix cart"), h("r1", 1001, null)];
  const env = [
    { n: 3, time: "1970-01-01 00:41:40 UTC", by: "a", verb: "set", note: "-", added: [], changed: ["B"], removed: [] },
    { n: 2, time: "1970-01-01 00:25:00 UTC", by: "a", verb: "set", note: "-", added: ["A"], changed: [], removed: [] },
  ];
  it("defaults to the previous release and the live one", () => {
    expect(defaultPair(releases)).toEqual({ from: "r2", to: "r3" });
    expect(defaultPair([rel("only", 1, true)])).toEqual({ from: "only", to: "only" });
    expect(defaultPair([])).toBeNull();
  });
  it("collects the deploys, their notes and the env changes after `from` up to `to`", () => {
    const c = changesBetween(releases, history, env as never, "r1", "r3");
    expect(c.deploys.map((x) => x.release)).toEqual(["r3", "r2"]);
    expect(c.notes.map((x) => x.note)).toEqual(["add search", "fix cart"]);
    expect(c.env.map((e) => e.n)).toEqual([3, 2]);
    expect(c.empty).toBe(false);
  });
  it("narrows with the pair and takes the two in either order", () => {
    const a = changesBetween(releases, history, env as never, "r2", "r3");
    expect(a.deploys.map((x) => x.release)).toEqual(["r3"]);
    expect(a.env.map((e) => e.n)).toEqual([3]);
    const b = changesBetween(releases, history, env as never, "r3", "r2");
    expect(b.deploys.map((x) => x.release)).toEqual(["r3"]);
    expect(b.from!.id).toBe("r2");
  });
  it("the same release twice, or an unknown one: nothing changed", () => {
    expect(changesBetween(releases, history, env as never, "r3", "r3").empty).toBe(true);
    expect(changesBetween(releases, history, env as never, "nope", "r3").empty).toBe(true);
  });
  it("works without the env log (the other sections still fill)", () => {
    const c = changesBetween(releases, history, null, "r1", "r3");
    expect(c.env).toEqual([]);
    expect(c.deploys).toHaveLength(2);
  });
  it("a rollback in between counts although its release is older", () => {
    const rb = h("r1", 2500, null, "rollback");
    const c = changesBetween(releases, [...history, rb], null, "r2", "r3");
    expect(c.deploys.map((x) => x.kind)).toContain("deploy");
    expect(changesBetween(releases, [rb], null, "r2", "r3").deploys).toHaveLength(1);
  });
  it("on the fixture: the live release against the one before it", () => {
    const d = snapApp.app!;
    const p = defaultPair(d.releases)!;
    expect(p).toEqual({ from: "20261116-101010", to: "20261117-101010" });
    const c = changesBetween(d.releases, d.history, envLog.entries, p.from, p.to);
    expect(c.deploys.map((x) => x.release)).toContain("20261117-101010");
  });
});

describe("deploy timeline across apps", () => {
  const base = snapApp.app!.history[0];
  const rows = [
    { ...base, host: "web-1", app: "shop", at: 100 }, { ...base, host: "web-1", app: "blog", at: 300, result: "failed" },
    { ...base, host: "web-2", app: "shop", at: 200, kind: "rollback" },
  ];
  it("newest first across hosts and apps", () => { expect(timeline(rows).map((r) => r.at)).toEqual([300, 200, 100]); });
  it("filters by server, app and result", () => {
    expect(timeline(rows, { host: "web-1", app: "", result: "" })).toHaveLength(2);
    expect(timeline(rows, { host: "", app: "shop", result: "" })).toHaveLength(2);
    expect(timeline(rows, { host: "", app: "", result: "failed" }).map((r) => r.app)).toEqual(["blog"]);
    expect(timeline(rows, { host: "web-2", app: "blog", result: "" })).toEqual([]);
  });
  it("options are the distinct values; keys are unique per row", () => {
    expect(timelineOptions(rows)).toEqual({ hosts: ["web-1", "web-2"], apps: ["blog", "shop"], results: ["failed", "verified"] });
    expect(new Set(rows.map(timelineKey)).size).toBe(3);
  });
});

describe("alerts", () => {
  it("firing first, then pending, across hosts, with the silenced flag", () => {
    const r = alertRows([{ host: "web-1", alerts: alerts.alerts }, { host: "web-2", alerts: [{ app: "x", check: "http", state: "firing", since: 5, detail: null }] }]);
    expect(r.firing.map((a) => `${a.host}/${a.app}`)).toEqual(["web-1/api", "web-2/x"]);
    expect(r.pending.map((a) => a.app)).toEqual(["host"]);
    expect(r.pending[0].silenced).toBe(true);
    expect(alertRows([{ host: "h", alerts: undefined }])).toEqual({ firing: [], pending: [] });
  });
  it("history events become spans: a resolve closes the open fire; an open fire is ongoing", () => {
    const now = alerts.checked_at!;
    const spans = alertSpans(alerts.history.map((e) => ({ ...e, host: "web-1" })), now);
    const shop = spans.find((s) => s.app === "shop")!;
    expect(shop).toMatchObject({ from: 1795241329, to: 1795242329, durationS: 1000, detail: "5xx at 12%" });
    const api = spans.find((s) => s.app === "api")!;
    expect(api).toMatchObject({ from: 1795246429, to: null, durationS: null });
    expect(spans[0].app).toBe("api"); // ongoing first
  });
  it("a resolve with no fire in the window keeps its end; old spans fall out of the 7 days", () => {
    const ev = [{ host: "h", app: "a", check: "c", event: "resolve", at: 100, detail: null }, { host: "h", app: "b", check: "c", event: "fire", at: 10, detail: null }, { host: "h", app: "b", check: "c", event: "resolve", at: 20, detail: null }];
    const s = alertSpans(ev, 100 + 86400, 50);
    expect(s).toHaveLength(1);
    expect(s[0]).toMatchObject({ app: "a", from: null, to: 100 });
  });
  it("flap and restart events do not make spans", () => {
    expect(alertSpans([{ host: "h", app: "a", check: "c", event: "flap", at: 1, detail: null }], 10, 0)).toEqual([]);
  });
});
