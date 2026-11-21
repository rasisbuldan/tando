import { describe, expect, it } from "vitest";
import { entryState, Studios, type OpenStudio, type StudioEnv } from "./studio";

const H = "web-1", A = "shop";
const URL1 = "http://127.0.0.1:47123/#c=abcDEF123_-";

interface Call { url: string; headers: Record<string, string>; body: Record<string, unknown> }
function fake(handler: (c: Call) => { status: number; body: unknown } | Promise<{ status: number; body: unknown }>) {
  const calls: Call[] = [], opened: string[] = [];
  let n = 0;
  const env: StudioEnv = {
    fetch: async (url, init) => {
      const c = { url, headers: init.headers, body: JSON.parse(init.body) };
      calls.push(c);
      const r = await handler(c);
      return { status: r.status, json: async () => r.body };
    },
    open: (u) => { opened.push(u); },
    uuid: () => `key-0000000${++n}`,
  };
  return { s: new Studios(env), calls, opened, posts: (p: string) => calls.filter((c) => c.url === p) };
}
const okServer = (c: Call) => c.url === "/api/confirm" ? { status: 200, body: { token: "tok-1", expires_in_s: 60 } }
  : c.url === "/api/studio/open" ? { status: 200, body: { url: URL1, host: H, app: A, since: "2026-11-21T14:02:00Z" } }
  : { status: 200, body: { stopped: true } };

describe("entry state", () => {
  const open: OpenStudio[] = [{ host: H, app: A, since: "2026-11-21T14:02:00Z", state: "open" }];
  it("closed, open, taken by another app of the server, starting", () => {
    expect(entryState(H, A, [], null)).toEqual({ kind: "closed" });
    expect(entryState(H, A, open, null)).toEqual({ kind: "open", since: "2026-11-21T14:02:00Z" });
    expect(entryState(H, "blog", open, null)).toEqual({ kind: "taken", by: A });
    expect(entryState("web-2", A, open, null)).toEqual({ kind: "closed" });
    expect(entryState(H, A, [{ ...open[0], state: "starting" }], null)).toEqual({ kind: "opening" });
  });
  it("opening while this tab's request is out", () => {
    const d = { host: H, app: A, token: "t", preparing: false, key: "k", sending: true, error: null, url: null };
    expect(entryState(H, A, [], d)).toEqual({ kind: "opening" });
  });
  it("the overview's list: odd entries dropped", () => {
    const { s } = fake(okServer);
    s.fromOverview([{ host: H, app: A, since: "x", state: "open" }, null, { host: 1 }]);
    expect(s.get().list).toHaveLength(1);
    s.fromOverview(undefined);
    expect(s.get().list).toEqual([]);
  });
});

describe("open", () => {
  it("asks for a confirm token of kind studio, opens with it and an Idempotency-Key, then the window", async () => {
    const f = fake(okServer);
    await f.s.ask(H, A);
    expect(f.posts("/api/confirm")[0].body).toEqual({ action: "studio", host: H, app: A });
    expect(f.s.get().dialog?.token).toBe("tok-1");
    expect(f.opened).toEqual([]); // nothing before the confirmation
    await f.s.confirm();
    const o = f.posts("/api/studio/open")[0];
    expect(o.body).toEqual({ host: H, app: A, confirm: "tok-1" });
    expect(o.headers["Idempotency-Key"]).toBe("key-00000001");
    expect(f.opened).toEqual([URL1]);
    expect(f.s.get().dialog?.url).toBe(URL1);
    expect(entryState(H, A, f.s.get().list, null).kind).toBe("open");
    await f.s.confirm(); // a second click: nothing more
    expect(f.posts("/api/studio/open")).toHaveLength(1);
  });
  it("a lost request: Open again sends the same key (no second studio)", async () => {
    let fail = true;
    const f = fake((c) => {
      if (c.url === "/api/studio/open" && fail) { fail = false; throw new Error("network"); }
      return okServer(c);
    });
    await f.s.ask(H, A);
    await f.s.confirm();
    expect(f.s.get().dialog?.error).toMatch(/did not answer/);
    await f.s.confirm();
    const keys = f.posts("/api/studio/open").map((c) => c.headers["Idempotency-Key"]);
    expect(keys).toEqual(["key-00000001", "key-00000001"]);
    expect(f.opened).toEqual([URL1]);
  });
  it("409: the server's words, no window", async () => {
    const f = fake((c) => c.url === "/api/studio/open"
      ? { status: 409, body: { error: { code: "studio_open", message: "the dashboard's studio on web-1 is open for blog: it is in the window it opened; Stop it to start a new one" } } }
      : okServer(c));
    await f.s.ask(H, A);
    await f.s.confirm();
    expect(f.opened).toEqual([]);
    expect(f.s.get().dialog?.error).toBe("the dashboard's studio on web-1 is open for blog: it is in the window it opened; Stop it to start a new one.");
  });
  it("a link that is not the studio's is never opened", async () => {
    const f = fake((c) => c.url === "/api/studio/open" ? { status: 200, body: { url: "javascript:alert(1)" } } : okServer(c));
    await f.s.ask(H, A);
    await f.s.confirm();
    expect(f.opened).toEqual([]);
  });
  it("Stop: the entry closes", async () => {
    const f = fake(okServer);
    f.s.fromOverview([{ host: H, app: A, since: "x", state: "open" }]);
    expect(await f.s.stop(H, A)).toBeNull();
    expect(f.posts("/api/studio/stop")[0].body).toEqual({ host: H, app: A });
    expect(entryState(H, A, f.s.get().list, null).kind).toBe("closed");
  });
});
