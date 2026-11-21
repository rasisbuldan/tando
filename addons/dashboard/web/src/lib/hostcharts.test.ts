import { describe, expect, it } from "vitest";
import { fixture } from "./fixtures";
import type { Snapshot } from "./types";
import { hostPoints, lastValue, loadMax, toPoints } from "./shape";

const snapHost = fixture<Snapshot>("snapshot-host");
const snapApp = fixture<Snapshot>("snapshot-app");

describe("Server page charts: the host series", () => {
  const m = snapHost.host_metrics!;
  it("has one point per bucket for load, cpu, memory and disk; gaps stay null", () => {
    for (const k of ["load", "cpu_percent", "memory_used_bytes", "disk_used_bytes"] as const) {
      const pts = hostPoints(m.series, k);
      expect(pts).toHaveLength(m.points);
      expect(pts.some((p) => p.v === null)).toBe(true);
    }
    // an older line has load and memory but no cpu or disk: a gap there only
    const old = m.series.findIndex((p) => p.load != null && p.cpu_percent == null);
    expect(old).toBeGreaterThanOrEqual(0);
    expect(hostPoints(m.series, "disk_used_bytes")[old].v).toBeNull();
    expect(hostPoints(m.series, "memory_used_bytes")[old].v).not.toBeNull();
  });
  it("limits: memory and disk totals from the newest bucket that has them", () => {
    expect(lastValue(m.series, "memory_total_bytes")).toBe(2048000000);
    expect(lastValue(m.series, "disk_total_bytes")).toBe(40000000000);
    expect(lastValue([], "disk_total_bytes")).toBeNull();
  });
  it("the load axis reaches the cores line (the limit) and the data", () => {
    expect(loadMax(0.4, 2)).toBe(2);
    expect(loadMax(3.1, 2)).toBe(5);
    expect(loadMax(null, null)).toBe(1);
  });
});

describe("App Overview: disk", () => {
  it("disk_bytes is a series like memory: null where no walk", () => {
    const pts = toPoints(snapApp.app!.metrics!.series, "disk_bytes");
    expect(pts.some((p) => p.v != null && p.v > 0)).toBe(true);
    expect(pts.some((p) => p.v === null)).toBe(true);
  });
});
