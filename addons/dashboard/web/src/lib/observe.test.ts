import { describe, expect, it } from "vitest";
import { fixture } from "./fixtures";
import type { Snapshot } from "./types";
import { appSliceStats, dbGrowthPerDay, dbPoints, extPoints, HOST_SECTIONS, multiPoints, pctPoints, queryRows, truncateQuery, wrapNote } from "./observe";

const host = fixture<Snapshot>("snapshot-host").host_metrics!;
const app = fixture<Snapshot>("snapshot-app").app!;
const at = <T extends { v: number | null }>(pts: T[], i: number) => pts[i];
const firstIdx = (a: (number | null)[] | undefined) => (a ?? []).findIndex((x) => x != null);

describe("host series: the extended arrays line up with the buckets", () => {
  it("one point per bucket; null stays a gap, never 0", () => {
    const pts = extPoints(host, "extended", "cpu_user_pct");
    expect(pts).toHaveLength(host.points);
    expect(pts.map((p) => p.t)).toEqual(host.series.map((p) => p.t));
    expect(pts.some((p) => p.v === null)).toBe(true);
    expect(pts.filter((p) => p.v != null)).toHaveLength(1);
  });
  it("per bucket counters become rates: bytes per second, operations per minute", () => {
    const i = firstIdx(host.extended!.net_in_bytes);
    expect(host.bucket_s).toBe(600);
    expect(at(extPoints(host, "extended", "net_in_bytes", "perSec"), i).v).toBe(1000); // 600000 B in 600 s
    expect(at(extPoints(host, "extended", "swap_out_pages", "perMin"), firstIdx(host.extended!.swap_out_pages)).v).toBeCloseTo(0.4);
    expect(at(extPoints(host, "extended", "disk_reads", "perSec"), firstIdx(host.extended!.disk_reads)).v).toBeCloseTo(0.2);
  });
  it("latency is shown in ms (the data is in us)", () => {
    const i = firstIdx(host.extended!.disk_latency_us);
    expect(at(extPoints(host, "extended", "disk_latency_us", "raw", 1000), i).v).toBeCloseTo(0.85);
  });
  it("monitoring cost: cpu ms a minute, programs started a minute", () => {
    expect(at(extPoints(host, "monitoring", "cpu_ms"), firstIdx(host.monitoring!.cpu_ms)).v).toBe(450);
    expect(at(extPoints(host, "monitoring", "children", "perMin"), firstIdx(host.monitoring!.children)).v).toBeCloseTo(0.3);
  });
  it("an older server without the arrays: all gaps, no throw", () => {
    const old = { ...host, extended: undefined, monitoring: undefined };
    const pts = extPoints(old, "extended", "cpu_user_pct");
    expect(pts).toHaveLength(host.points);
    expect(pts.every((p) => p.v === null)).toBe(true);
  });
  it("percent of a total, per bucket (disk usage from the totals)", () => {
    const pts = pctPoints(host.series, "disk_used_bytes", "disk_total_bytes");
    const i = host.series.findIndex((p) => p.disk_used_bytes != null && p.disk_total_bytes);
    expect(pts[i].v).toBeCloseTo((host.series[i].disk_used_bytes! / host.series[i].disk_total_bytes!) * 100);
    expect(pts.some((p) => p.v === null)).toBe(true);
  });
});

describe("several lines in one chart", () => {
  it("stacked: v is the stack's height, each line keeps its own value, a gap is a gap", () => {
    const user = extPoints(host, "extended", "cpu_user_pct"), sys = extPoints(host, "extended", "cpu_system_pct");
    const io = extPoints(host, "extended", "cpu_iowait_pct"), steal = extPoints(host, "extended", "cpu_steal_pct");
    const pts = multiPoints([user, sys, io, steal], true);
    const i = firstIdx(host.extended!.cpu_user_pct);
    expect(pts[i].s).toEqual([12.5, 4, 1.2, 0.3]);
    expect(pts[i].v).toBeCloseTo(18);
    const gap = pts.findIndex((p) => p.v === null);
    expect(pts[gap].s.every((x) => x === null)).toBe(true);
  });
  it("not stacked: v is the highest line (the axis follows it)", () => {
    const pts = multiPoints([[{ t: 1, v: 2 }], [{ t: 1, v: 5 }]], false);
    expect(pts[0].v).toBe(5);
    expect(multiPoints([[{ t: 1, v: null }], [{ t: 1, v: 3 }]], false)[0].s).toEqual([null, 3]);
  });
});

describe("the Server page's sections", () => {
  const names = HOST_SECTIONS.map((s) => s.title);
  it("the cloud-console set, in order", () => {
    expect(names).toEqual(["CPU", "Memory", "Disk", "Network", "Pressure", "Monitoring cost"]);
    expect(HOST_SECTIONS.flatMap((s) => s.charts)).toHaveLength(20);
  });
  it("every chart has a title and a unit; steal and swap carry no alert colour", () => {
    for (const c of HOST_SECTIONS.flatMap((s) => s.charts)) {
      expect(c.title.length).toBeGreaterThan(0);
      for (const l of c.lines ?? []) expect(l.color).not.toMatch(/warn|fail/);
    }
    const cpu = HOST_SECTIONS[0].charts.find((c) => c.id === "cpu")!;
    expect(cpu.lines!.map((l) => l.name)).toEqual(["User", "System", "I/O wait", "Steal"]);
    expect(cpu.stack).toBe(true);
    expect(cpu.lines!.find((l) => l.name === "Steal")!.color).toBe("var(--faint)");
  });
  it("reader requests are a chart of their own, not a line of the cost chart", () => {
    const m = HOST_SECTIONS.find((s) => s.title === "Monitoring cost")!.charts;
    expect(m.map((c) => c.id)).toEqual(["mon-cpu", "mon-mem", "mon-progs", "mon-reqs"]);
    expect(m.find((c) => c.id === "mon-reqs")!.lines).toBeUndefined();
  });
});

describe("app slice stats", () => {
  it("latest throttled %, OOM kills in the range, tasks against the limit, memory pressure", () => {
    const s = appSliceStats(app.metrics!.series);
    expect(s.throttled).toBe(0);
    expect(s.oomKills).toBe(2);
    expect(s.tasks).toBe(18);
    expect(s.tasksMax).toBe(512);
    expect(s.pressure).toBeCloseTo(0.05);
  });
  it("older data: nothing, not zeros", () => {
    const s = appSliceStats([{ t: 1, memory_bytes: 1, cpu_percent: 1, restarts: 0, state: "a" }]);
    expect(s).toEqual({ throttled: null, oomKills: null, tasks: null, tasksMax: null, pressure: null });
  });
});

describe("database", () => {
  it("a series by key; connections by state; gaps stay gaps", () => {
    const pts = dbPoints(app.database!.series, "cache_hit_pct");
    expect(pts).toHaveLength(app.database!.series!.length);
    expect(pts.some((p) => p.v != null)).toBe(true);
    expect(pts.some((p) => p.v === null)).toBe(true);
  });
  it("growth per day from the size between the first and last known points", () => {
    const g = dbGrowthPerDay([{ t: 0, size_bytes: 1000 }, { t: 43200, size_bytes: null }, { t: 86400, size_bytes: 3000 }] as never);
    expect(g).toBe(2000);
    expect(dbGrowthPerDay([{ t: 0, size_bytes: 1000 }] as never)).toBeNull();
    expect(dbGrowthPerDay([])).toBeNull();
  });
  it("top queries: truncated text, never HTML, sorted as given, ms and counts kept", () => {
    expect(truncateQuery("SELECT   *\n FROM  t", 80)).toBe("SELECT * FROM t");
    const long = "SELECT " + "x, ".repeat(100);
    expect(truncateQuery(long, 60)).toHaveLength(60);
    expect(truncateQuery(long, 60).endsWith("…")).toBe(true);
    const rows = queryRows(app.database!.top_queries);
    expect(rows.length).toBe((app.database!.top_queries?.queries.length ?? 0));
    expect(queryRows(null)).toEqual([]);
    expect(queryRows({ t: 1, queries: [{ query: "<img src=x onerror=alert(1)>", calls: 1, mean_ms: 1, total_ms: 1, rows: 1 }] })[0].text).toBe("<img src=x onerror=alert(1)>");
  });
  it("wraparound note only when it matters", () => {
    expect(wrapNote(null)).toBeNull();
    expect(wrapNote(3)).toBeNull();
    expect(wrapNote(60)).toMatch(/60/);
  });
});

describe("the Database tab's charts", () => {
  it("the set the owner asked for, no alert colour in a series", async () => {
    const { DB_CHARTS } = await import("./observe");
    expect(DB_CHARTS.map((c) => c.id)).toEqual(["conns", "tx", "rows", "cache", "deadlocks", "temp", "long", "size"]);
    const rows = DB_CHARTS.find((c) => c.id === "rows")!;
    expect(rows.lines.map((l) => l.name)).toEqual(["Returned", "Fetched", "Inserted", "Updated", "Deleted"]);
    expect(DB_CHARTS.find((c) => c.id === "conns")!.limit).toBe("max_connections");
    for (const l of DB_CHARTS.flatMap((c) => c.lines)) expect(l.color).not.toMatch(/warn|fail/);
  });
});
