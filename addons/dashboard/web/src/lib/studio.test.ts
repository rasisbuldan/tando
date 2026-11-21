import { describe, expect, it } from "vitest";
import { Studios, studioTarget, type StudioEnv, type Tab } from "./studio";

const H = "web-1", A = "shop";
const URL1 = "http://127.0.0.1:47123/#c=abcDEF123_-&app=shop";

interface Call { url: string; headers: Record<string, string>; body: Record<string, unknown> }
function fake(handler: (c: Call) => { status: number; body: unknown } | Promise<{ status: number; body: unknown }>, popups = true) {
  const calls: Call[] = [], navigated: string[] = [], closed: number[] = [], direct: string[] = [];
  let tabs = 0;
  const env: StudioEnv = {
    fetch: async (url, init) => {
      const c = { url, headers: init.headers, body: JSON.parse(init.body) };
      calls.push(c);
      const r = await handler(c);
      return { status: r.status, json: async () => r.body };
    },
    // the tab is opened on the click itself, before the request, so a pop-up blocker lets it through
    openTab: (): Tab | null => {
      if (!popups) return null;
      const id = ++tabs;
      return { go: (u) => { navigated.push(u); }, close: () => { closed.push(id); } };
    },
    openUrl: (u) => { direct.push(u); return true; },
  };
  return { s: new Studios(env), calls, navigated, closed, direct };
}
const ok = () => ({ status: 200, body: { url: URL1, host: H, app: A } });

describe("studioTarget", () => {
  it("the server's studio opens on its first app with a database", () => {
    expect(studioTarget([{ app: "api", database: null }, { app: "shop", database: "postgres" }, { app: "blog", database: "postgres" }])).toBe("shop");
    expect(studioTarget([{ app: "api", database: null }])).toBeNull();
    expect(studioTarget(undefined)).toBeNull();
  });
});

describe("open: no dialog, no confirm token", () => {
  it("one POST, no token and no Idempotency-Key, then the tab goes to the link", async () => {
    const f = fake(ok);
    await f.s.open(H, A);
    expect(f.calls).toHaveLength(1);
    expect(f.calls[0].url).toBe("/api/studio/open");
    expect(f.calls[0].body).toEqual({ host: H, app: A });
    expect(f.calls[0].headers["Idempotency-Key"]).toBeUndefined();
    expect(f.navigated).toEqual([URL1]);
    expect(f.s.get().error).toBeNull();
    expect(f.s.get().opening).toEqual([]);
  });
  it("every click mints again: a link is never reused", async () => {
    const f = fake(ok);
    await f.s.open(H, A);
    await f.s.open(H, A);
    expect(f.calls).toHaveLength(2);
  });
  it("while a click is out, the same entry is opening and a second click does nothing", async () => {
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => { release = r; });
    const f = fake(async () => { await gate; return ok(); });
    const p = f.s.open(H, A);
    expect(f.s.get().opening).toEqual([`${H}/${A}`]);
    await f.s.open(H, A);
    release();
    await p;
    expect(f.calls).toHaveLength(1);
    expect(f.s.get().opening).toEqual([]);
  });
});

describe("failures", () => {
  it("the server's words on a refusal; the tab is closed, nothing navigates", async () => {
    const f = fake(() => ({ status: 502, body: { error: { code: "cli", message: "the studio on web-1 gave no code (tando doctor web-1)" } } }));
    await f.s.open(H, A);
    expect(f.navigated).toEqual([]);
    expect(f.closed).toEqual([1]);
    expect(f.s.get().error).toBe("the studio on web-1 gave no code (tando doctor web-1).");
  });
  it("a request that did not answer: one line, tab closed", async () => {
    const f = fake(() => { throw new Error("network"); });
    await f.s.open(H, A);
    expect(f.s.get().error).toMatch(/did not answer/);
    expect(f.closed).toEqual([1]);
  });
  it("a link that is not the studio's is never opened", async () => {
    const f = fake(() => ({ status: 200, body: { url: "javascript:alert(1)" } }));
    await f.s.open(H, A);
    expect(f.navigated).toEqual([]);
    expect(f.direct).toEqual([]);
    expect(f.s.get().error).toMatch(/not the studio/i);
  });
  it("a pop-up blocker: the link opens directly after the answer, else a line says what to do", async () => {
    const f = fake(ok, false);
    await f.s.open(H, A);
    expect(f.direct).toEqual([URL1]);
    const g = fake(ok, false);
    g.s["env"].openUrl = () => false;
    await g.s.open(H, A);
    expect(g.s.get().error).toMatch(/pop-up/i);
  });
  it("dismiss clears the line", async () => {
    const f = fake(() => ({ status: 500, body: {} }));
    await f.s.open(H, A);
    expect(f.s.get().error).not.toBeNull();
    f.s.dismiss();
    expect(f.s.get().error).toBeNull();
  });
});
