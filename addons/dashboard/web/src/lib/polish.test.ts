// The seven items of the lead's polish list (dashboard-polish-1), the ones that can be tested as data.
import { describe, expect, it } from "vitest";
import { fixture } from "./fixtures";
import type { Snapshot } from "./types";
import { allZero, chartDomain, cpuMax, deployMarkers, markersNear, markerText, memoryTicks, phases, rollbackTarget, roundTicks, toPoints } from "./shape";
import { fmtBytes, fmtDurShort, fmtDur, fmtPct } from "./format";
import { readFileSync } from "node:fs";

const snapApp = fixture<Snapshot>("snapshot-app");
const MB = 1024 * 1024;

describe("1. memory ticks are round", () => {
  it("512 MB cap: 0, 200, 400 MB (never 238, 477)", () => {
    const t = memoryTicks(512 * MB);
    expect(t.map((x) => x / MB)).toEqual([0, 200, 400]);
    expect(t.map(fmtBytes)).toEqual(["0 MB", "200 MB", "400 MB"]);
  });
  it("650 MB data: 0, 200, 400, 600", () => { expect(memoryTicks(650 * MB).map((x) => x / MB)).toEqual([0, 200, 400, 600]); });
  it("large axes use GB steps", () => {
    const t = memoryTicks(3 * 1024 * MB);
    expect(t.map(fmtBytes)).toEqual(["0 MB", "1.0 GB", "2.0 GB", "3.0 GB"]);
  });
  it("at most 5 ticks and always starts at 0", () => {
    for (const m of [10, 64, 100, 238, 477, 512, 1000, 1500, 4096]) { const t = memoryTicks(m * MB); expect(t[0]).toBe(0); expect(t.length).toBeLessThanOrEqual(5); expect(t.length).toBeGreaterThan(1); }
  });
  it("roundTicks on plain numbers", () => { expect(roundTicks(10)).toEqual([0, 2.5, 5, 7.5, 10]); expect(roundTicks(4)).toEqual([0, 1, 2, 3, 4]); expect(roundTicks(0)).toEqual([0]); });
});

describe("2. restarts with none", () => {
  it("all-zero data is the 'No restarts' state; no data or some restarts is not", () => {
    expect(allZero([{ t: 1, v: 0 }, { t: 2, v: 0 }, { t: 3, v: null }])).toBe(true);
    expect(allZero([{ t: 1, v: 0 }, { t: 2, v: 1 }])).toBe(false);
    expect(allZero([{ t: 1, v: null }])).toBe(false);
    expect(allZero([])).toBe(false);
  });
  it("the card says it in the plot box (the chart is not drawn)", () => {
    const src = readFileSync(new URL("../components/chart-card.tsx", import.meta.url), "utf8");
    expect(src).toContain("zeroText");
    const app = readFileSync(new URL("../pages/app.tsx", import.meta.url), "utf8");
    expect(app).toContain("No restarts in ${rangeWord}");
  });
});

describe("3. deploy markers say what they are", () => {
  const m = snapApp.app!.metrics!;
  const d = chartDomain("7d", snapApp.server_now, m);
  const markers = deployMarkers(snapApp.app!.history, d);
  it("carry release, kind and result", () => {
    expect(markers.length).toBeGreaterThan(0);
    expect(markerText(markers[0])).toBe("r 20261117-101010 · deploy · verified");
    expect(markers.find((x) => x.kind === "rollback")).toBeTruthy();
  });
  it("a chart hover finds the markers near it", () => {
    expect(markersNear(markers, markers[0].t + 30, 60)).toHaveLength(1);
    expect(markersNear(markers, markers[0].t + 3600, 60)).toEqual([]);
    expect(markersNear(undefined, 1, 1)).toEqual([]);
  });
  it("the plot draws a hover target on each marker", () => {
    expect(readFileSync(new URL("../charts/index.tsx", import.meta.url), "utf8")).toContain("<title>{text}</title>");
  });
});

describe("4. rollback target", () => {
  it("is the previous verified release, not the live one and not a failed one", () => {
    expect(rollbackTarget(snapApp.app!.releases)).toBe("20261116-101010");
  });
  it("skips a failed release in between; none when nothing else is verified", () => {
    const r = (id: string, at: number, status: string, current = false) => ({ id, deployed_at: at, status, current, last_good: current });
    expect(rollbackTarget([r("c", 3, "verified", true), r("b", 2, "failed"), r("a", 1, "verified")])).toBe("a");
    expect(rollbackTarget([r("c", 3, "verified", true), r("b", 2, "failed")])).toBeNull();
    expect(rollbackTarget([])).toBeNull();
  });
});

describe("5. phase legend and hover", () => {
  it("six phases in order, each with seconds for the hover", () => {
    const p = phases(snapApp.app!.history[0]);
    expect(p).toHaveLength(6);
    const src = readFileSync(new URL("../components/bits.tsx", import.meta.url), "utf8");
    expect(src).toContain("`${p.label} ${fmtSecs(p.s)}`");
    expect(src).toContain("export function PhaseLegend");
  });
  it("the legend is above the history table, once", () => {
    const t = readFileSync(new URL("../components/history-table.tsx", import.meta.url), "utf8");
    expect(t.match(/<PhaseLegend \/>/g)).toHaveLength(1);
    expect(t.indexOf("<PhaseLegend />")).toBeLessThan(t.indexOf("<Table"));
  });
});

describe("6. durations in the history column", () => {
  it("short form, no ellipsis needed", () => {
    expect(fmtDurShort(73)).toBe("1m 13s");
    expect(fmtDurShort(48)).toBe("48s");
    expect(fmtDurShort(60)).toBe("1m");
    expect(fmtDurShort(12000)).toBe("3h 20m");
    expect(fmtDurShort(4 * 86400)).toBe("4d");
    expect(fmtDurShort(null)).toBe("—");
    expect(fmtDur(73)).toBe("1 min 13 s"); // the long form stays for prose
  });
  it("the phase bar's total uses it and does not wrap", () => {
    const src = readFileSync(new URL("../components/bits.tsx", import.meta.url), "utf8");
    expect(src).toContain("fmtDurShort(total)");
    expect(src).toContain("whitespace-nowrap");
  });
});

describe("7. CPU axis scaled to the data", () => {
  it("mostly idle: at least 10 %, not 100", () => {
    const cpu = toPoints(snapApp.app!.metrics!.series, "cpu_percent");
    const max = Math.max(...cpu.map((p) => p.v ?? 0));
    expect(max).toBeGreaterThan(0);
    expect(cpuMax(max)).toBe(20);
    expect(cpuMax(0)).toBe(10);
    expect(cpuMax(null)).toBe(10);
    expect(cpuMax(3)).toBe(10);
  });
  it("grows with the data and stops at 100", () => {
    expect(cpuMax(42)).toBe(50);
    expect(cpuMax(180)).toBe(100);
    expect(cpuMax(100)).toBe(100);
  });
  it("its ticks are round percentages", () => { expect(roundTicks(cpuMax(3)).map(fmtPct)).toEqual(["0%", "2.5%", "5%", "7.5%", "10%"]); });
});
