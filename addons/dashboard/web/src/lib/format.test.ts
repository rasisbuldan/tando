import { describe, expect, it } from "vitest";
import { fmtAgo, fmtBytes, fmtDateTime, fmtDur, fmtFor, fmtPct, fmtTime, shortId } from "./format";

describe("format (copy rules 8-11)", () => {
  it("bytes: MB below 1 GB, GB with one decimal, missing is a dash", () => {
    expect(fmtBytes(104857600)).toBe("100 MB");
    expect(fmtBytes(1.4 * 1024 ** 3)).toBe("1.4 GB");
    expect(fmtBytes(null)).toBe("—");
  });
  it("percent: no decimals except under 10", () => { expect(fmtPct(80.4)).toBe("80%"); expect(fmtPct(0.44)).toBe("0.4%"); expect(fmtPct(3.4)).toBe("3.4%"); });
  it("durations", () => {
    expect(fmtDur(48)).toBe("48 s"); expect(fmtDur(130)).toBe("2 min 10 s"); expect(fmtDur(3 * 3600 + 1200)).toBe("3 h 20 min"); expect(fmtDur(4 * 86400)).toBe("4 d");
  });
  it("times are GMT, 24 h", () => {
    expect(fmtTime(1795247326)).toBe("07:48 GMT");
    expect(fmtDateTime(1795247326)).toMatch(/^\d{1,2} [A-Z][a-z]{2} 07:48 GMT$/);
  });
  it("relative ages", () => {
    expect(fmtAgo(1000, 998)).toBe("just now"); expect(fmtAgo(1000, 988)).toBe("12 s ago"); expect(fmtAgo(1000, 700)).toBe("5 min ago");
    expect(fmtAgo(100000, 100000 - 3 * 3600)).toBe("3 h ago"); expect(fmtAgo(1e6, 1e6 - 2 * 86400)).toBe("2 d ago");
    expect(fmtFor(1000, 280)).toBe("for 12 min");
  });
  it("ids truncate in the middle", () => { expect(shortId("20261121-140233")).toBe("2026…140233"); expect(shortId(null)).toBe("—"); });
});
