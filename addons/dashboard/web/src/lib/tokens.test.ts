import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// parses src/styles/tokens.css and asserts the WCAG pairs of docs/DESIGN.md section 2
const css = readFileSync(new URL("../styles/tokens.css", import.meta.url), "utf8");
function block(sel: string): Record<string, string> {
  const out: Record<string, string> = {};
  const m = css.match(new RegExp(`${sel}\\s*\\{([^}]*)\\}`));
  for (const [, k, v] of (m?.[1] ?? "").matchAll(/--([\w-]+):\s*(#[0-9a-f]{6})/gi)) out[k] = v;
  return out;
}
const lum = (hex: string) => {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
};
const ratio = (a: string, b: string) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

describe("tokens contrast", () => {
  for (const [name, t0] of [["light", block(":root")], ["dark", { ...block(":root"), ...block("\\.dark") }]] as const) {
    it(`${name}: text >= 4.5 on card and background`, () => {
      for (const k of ["foreground", "muted-foreground", "faint", "ok", "warn", "fail", "stale", "info", "neutral"]) {
        expect(ratio(t0[k], t0.card), `${k} on card`).toBeGreaterThanOrEqual(4.5);
        expect(ratio(t0[k], t0.background), `${k} on background`).toBeGreaterThanOrEqual(4.5);
      }
    });
    it(`${name}: control border >= 3 and chart colours >= 3 on card`, () => {
      expect(ratio(t0.input, t0.card)).toBeGreaterThanOrEqual(3);
      for (let i = 1; i <= 6; i++) expect(ratio(t0[`chart-${i}`], t0.card), `chart-${i}`).toBeGreaterThanOrEqual(3);
    });
  }
});
