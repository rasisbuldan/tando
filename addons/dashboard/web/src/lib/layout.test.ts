import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// The shell's scroll structure (owner: the sidebar stays fixed, also while the main pane is pulled
// past its end): the page itself never scrolls; only <main> does, and it does not chain or bounce.
const src = (f: string) => readFileSync(new URL(f, import.meta.url), "utf8");

describe("shell scrolling", () => {
  it("the page is not a scroller and has no overscroll", () => {
    const css = src("../styles/app.css");
    expect(css).toMatch(/html, body \{[^}]*overflow: hidden;[^}]*overscroll-behavior: none/);
  });
  it("the shell is one viewport high; main is the only scroll container and does not bounce", () => {
    const app = src("../App.tsx");
    expect(app).toMatch(/className="flex h-dvh overflow-hidden"/);
    expect(app).toMatch(/<main[^>]*className="[^"]*\boverflow-y-auto\b[^"]*\boverscroll-none\b/);
  });
  it("the sidebar is not sticky or document-high: it fills the shell and scrolls only its own list", () => {
    const sb = src("../components/sidebar.tsx");
    expect(sb).not.toMatch(/sticky|h-screen|min-h-screen/);
    expect(sb).toMatch(/role="tree"[^>]*overscroll-contain/);
  });
});
