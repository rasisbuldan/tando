import { describe, expect, it } from "vitest";
import {
  Actions, commandFor, conflictLine, deployBlocked, dialogCopy, endView, envKeyError, envValueError, readSse, refusedLine, runningLine, STORE_KEY,
  type ActionEnv, type ActionRecord, type Resp,
} from "./actions";

const H = "web-1", A = "shop";
const flush = async () => { for (let i = 0; i < 30; i++) await new Promise<void>((r) => setImmediate(r)); };

function sse(...events: string[]): ReadableStream<Uint8Array> {
  const enc = new TextEncoder();
  return new ReadableStream({ start(c) { for (const e of events) c.enqueue(enc.encode(e)); c.close(); } });
}
const ev = (name: string, data: unknown, id?: number) => `${id ? `id: ${id}\n` : ""}event: ${name}\ndata: ${JSON.stringify(data)}\n\n`;
const json = (status: number, body: unknown): Resp => ({ ok: status < 300, status, json: async () => body, body: null });

interface Call { url: string; method: string; headers: Record<string, string>; body?: string }
type Handler = (c: Call) => Resp | Promise<Resp>;

/** fake fetch, storage, uuid and timers; every storage write is kept to check what was stored */
function fake(handler: Handler, store = new Map<string, string>()) {
  const calls: Call[] = [];
  const writes: string[] = [];
  const timers = new Map<number, () => void>();
  let id = 0, uuid = 0;
  const env: ActionEnv = {
    fetch: async (url, init) => { const c = { url, method: init.method, headers: init.headers, body: init.body }; calls.push(c); return handler(c); },
    storage: {
      getItem: (k) => store.get(k) ?? null,
      setItem: (k, v) => { writes.push(v); store.set(k, v); },
      removeItem: (k) => { store.delete(k); },
    },
    uuid: () => `key-0000000${++uuid}`,
    now: () => Date.parse("2026-11-21T14:02:40Z"), rand: () => 0.5,
    setTimeout: (f) => { timers.set(++id, f); return id; },
    clearTimeout: (h) => { timers.delete(h as number); },
  };
  const fireAll = async () => { const fs = [...timers.values()]; timers.clear(); fs.forEach((f) => f()); await flush(); };
  return { env, calls, writes, store, fireAll, posts: (p: string) => calls.filter((c) => c.method === "POST" && c.url === p) };
}

const rec = (p: Partial<ActionRecord> = {}): ActionRecord => ({ key: "key-00000001", action: "restart", host: H, app: A, status: "running", started_at: "2026-11-21T14:02:00Z", ...p });
const endRec = (p: Partial<ActionRecord> = {}) => rec({ status: "done", ended_at: "2026-11-21T14:02:04Z", exit: 0, outcome: { checked_at: "x", state: "running", verdict: "ok", summary: "shop is running" }, ...p });

/** a tando-dash that answers the confirm and the action, and streams the write to its end */
function server(action: (c: Call, n: number) => Resp | Promise<Resp>) {
  let n = 0, act = "restart";
  return (c: Call): Resp | Promise<Resp> => {
    if (c.url === "/api/confirm") return json(200, { token: `tok${++n}`, expires_in_s: 60 });
    if (c.url === "/api/action" && c.method === "POST") { act = JSON.parse(c.body!).action; return action(c, n); }
    if (c.url.startsWith("/api/action/stream")) return { ok: true, status: 200, json: async () => null, body: sse(ev("hello", rec({ action: act })), ev("line", { n: 1, text: "tando: working" }, 1), ev("end", endRec({ action: act }))) };
    return json(404, { error: { code: "not_found", message: "no" } });
  };
}

describe("the action state machine", () => {
  it("asks for the confirm token when the dialog opens; Preparing until it arrives", async () => {
    const f = fake(server(() => json(202, rec())));
    const a = new Actions(f.env);
    a.open(H, A, "restart");
    expect(a.get(H, A).dialog).toMatchObject({ preparing: true, token: null });
    await flush();
    expect(JSON.parse(f.posts("/api/confirm")[0].body!)).toEqual({ action: "restart", host: H, app: A });
    expect(a.get(H, A).dialog).toMatchObject({ preparing: false, token: "tok1" });
  });

  it("a token that does not come is one line, and confirming does nothing", async () => {
    const f = fake((c) => (c.url === "/api/confirm" ? Promise.reject(new Error("aborted")) : json(500, {})));
    const a = new Actions(f.env);
    a.open(H, A, "stop");
    await flush();
    expect(a.get(H, A).dialog?.tokenError).toBe("Could not prepare this: tando-dash did not answer in 2 s. Close and try again.");
    await a.send(H, A);
    expect(f.posts("/api/action")).toHaveLength(0);
  });

  it("a double click sends once", async () => {
    const f = fake(server(() => json(202, rec())));
    const a = new Actions(f.env);
    a.open(H, A, "restart"); await flush();
    void a.send(H, A); void a.send(H, A);
    await flush();
    expect(f.posts("/api/action")).toHaveLength(1);
    expect(a.get(H, A).dialog).toBeNull();
    expect(a.get(H, A).op?.key).toBe("key-00000001");
  });

  it("a retry after a network error sends the same Idempotency-Key (with a fresh token)", async () => {
    let tries = 0;
    const f = fake(server((c) => { tries++; if (tries === 1) throw new Error("network"); return json(200, { ...rec({ key: c.headers["Idempotency-Key"] }), replay: true }); }));
    const a = new Actions(f.env);
    a.open(H, A, "restart"); await flush();
    await a.send(H, A); await flush();
    const d = a.get(H, A).dialog!;
    expect(d).toMatchObject({ sendFailed: true, sending: false, key: "key-00000001" });
    expect(d.error).toBe("Could not reach tando-dash. Retry sends the same request; it runs once.");
    // a reload now would find it: the key is kept
    expect(JSON.parse(f.store.get(STORE_KEY)!)).toEqual([{ key: "key-00000001", host: H, app: A, action: "restart" }]);
    await a.send(H, A); await flush();
    const sent = f.posts("/api/action");
    expect(sent.map((c) => c.headers["Idempotency-Key"])).toEqual(["key-00000001", "key-00000001"]);
    expect(sent.map((c) => JSON.parse(c.body!).confirm)).toEqual(["tok1", "tok2"]);
    expect(a.get(H, A).op).toMatchObject({ key: "key-00000001", replay: true });
  });

  it("a new action after the end gets a new key", async () => {
    const f = fake(server(() => json(202, rec())));
    const a = new Actions(f.env);
    a.open(H, A, "restart"); await flush(); await a.send(H, A); await flush();
    expect(a.get(H, A).op?.status).toBe("done");
    a.close(H, A);
    a.open(H, A, "restart"); await flush(); await a.send(H, A); await flush();
    expect(f.posts("/api/action").map((c) => c.headers["Idempotency-Key"])).toEqual(["key-00000001", "key-00000002"]);
  });

  it("409: says what runs and since when; Show progress follows that write", async () => {
    const running = { action: "rollback", since: "2026-11-21T14:02:00Z", key: "other-key-123" };
    const f = fake(server(() => json(409, { error: { code: "running", message: "a rollback of shop is running", running } })));
    const a = new Actions(f.env);
    a.open(H, A, "deploy"); await flush(); await a.send(H, A); await flush();
    expect(a.get(H, A).dialog?.conflict).toEqual(running);
    expect(f.store.has(STORE_KEY)).toBe(false); // our write never ran: nothing to reattach to
    expect(conflictLine(A, running, f.env.now())).toBe("A rollback of shop is running, started 14:02 GMT (40 s ago).");
    a.view(H, A, running); await flush();
    expect(f.calls.some((c) => c.url === "/api/action/stream?key=other-key-123")).toBe(true);
    expect(a.get(H, A).op).toMatchObject({ key: "other-key-123", watching: true });
  });

  it("an idempotent replay shows the first request's result", async () => {
    const f = fake(server(() => json(200, { ...endRec(), replay: true })));
    const a = new Actions(f.env);
    a.open(H, A, "restart"); await flush(); await a.send(H, A); await flush();
    const o = a.get(H, A).op!;
    expect(o.replay).toBe(true);
    expect(o.status).toBe("done");
  });

  it("a refusal (422 deploy_folder) is one line in the dialog, and a new token is asked for", async () => {
    const f = fake(server(() => json(422, { error: { code: "deploy_folder", message: "shop was last deployed from bob@box, not from this machine (alice@mac): deploy from there" } })));
    const a = new Actions(f.env);
    a.open(H, A, "deploy"); await flush(); await a.send(H, A); await flush();
    expect(a.get(H, A).dialog?.error).toBe("Deploy refused: shop was last deployed from bob@box, not from this machine (alice@mac): deploy from there.");
    expect(a.get(H, A).dialog?.token).toBe("tok2");
    expect(f.store.has(STORE_KEY)).toBe(false);
  });

  it("the stream resumes with Last-Event-ID and never repeats a line; the end is the server's record", async () => {
    let streams = 0;
    const f = fake((c) => {
      if (c.url === "/api/confirm") return json(200, { token: "t" });
      if (c.method === "POST") return json(202, rec({ action: "deploy" }));
      streams++;
      if (streams === 1) return { ok: true, status: 200, json: async () => null, body: sse(ev("hello", rec()), ev("line", { n: 1, text: "build" }, 1), ev("line", { n: 2, text: "upload" }, 2)) };
      expect(c.headers["Last-Event-ID"]).toBe("2");
      return { ok: true, status: 200, json: async () => null, body: sse(ev("hello", rec()), ev("line", { n: 2, text: "upload" }, 2), ev("line", { n: 3, text: "switch" }, 3),
        ev("end", endRec({ action: "deploy", outcome: { checked_at: "x", release: "20261121-140233", history: { at: 1, release: "20261121-140233", kind: "deploy", result: "verified", total_s: 48 }, verdict: "ok", summary: "" } }))) };
    });
    const a = new Actions(f.env);
    a.open(H, A, "deploy"); await flush(); await a.send(H, A); await flush();
    expect(a.get(H, A).op?.lines).toEqual(["build", "upload"]);
    expect(f.store.has(STORE_KEY)).toBe(true);
    await f.fireAll(); // the backoff before reconnecting
    const o = a.get(H, A).op!;
    expect(o.lines).toEqual(["build", "upload", "switch"]);
    expect(o.status).toBe("done");
    expect(endView(o.record!).line).toBe("Deployed 20261121-140233 in 48 s.");
    expect(f.store.has(STORE_KEY)).toBe(false); // ended: nothing to reattach to
  });

  it("reattaches after a reload from sessionStorage (key and app only)", async () => {
    const store = new Map([[STORE_KEY, JSON.stringify([{ key: "key-abcdef12", host: H, app: A, action: "deploy" }, { key: "gone-key-1234", host: H, app: "blog", action: "stop" }])]]);
    const f = fake((c) => {
      if (c.url === "/api/action?key=key-abcdef12") return json(200, rec({ key: "key-abcdef12", action: "deploy", output: "x" }));
      if (c.url === "/api/action?key=gone-key-1234") return json(404, { error: { code: "not_found", message: "no write" } });
      return { ok: true, status: 200, json: async () => null, body: sse(ev("hello", rec({ key: "key-abcdef12", action: "deploy" })), ev("line", { n: 1, text: "build" }, 1)) };
    }, store);
    const a = new Actions(f.env);
    await a.reattach(); await flush();
    expect(a.get(H, A).op).toMatchObject({ key: "key-abcdef12", reattached: true, action: "deploy", lines: ["build"] });
    expect(a.get(H, "blog").op).toBeNull();
    expect(JSON.parse(store.get(STORE_KEY)!)).toEqual([{ key: "key-abcdef12", host: H, app: A, action: "deploy" }]);
    expect(runningLine(a.get(H, A).op!, f.env.now())).toBe("Deploying shop · started 14:02 GMT · 40 s");
  });

  it("an env value is never stored: not in sessionStorage, not in the state", async () => {
    const VAL = "never-kept-x9";
    const f = fake(server(() => json(202, rec({ action: "env-set" }))));
    const a = new Actions(f.env);
    const states: string[] = [];
    a.subscribe(() => states.push(JSON.stringify(a.all())));
    a.open(H, A, "env-set"); await flush();
    await a.send(H, A, VAL, { key: "API_TOKEN" }); await flush();
    const body = JSON.parse(f.posts("/api/action")[0].body!);
    expect(body.params).toEqual({ key: "API_TOKEN", value: VAL }); // the request body is the only place
    expect(f.writes.length).toBeGreaterThan(0);
    for (const w of f.writes) expect(w).not.toContain(VAL);
    expect([...f.store.values()].join()).not.toContain(VAL);
    for (const s of states) expect(s).not.toContain(VAL);
    expect(f.calls.every((c) => !c.url.includes(VAL))).toBe(true);
    expect(endView(a.get(H, A).op!.record!, a.get(H, A).op!.varName).line).toBe("Set API_TOKEN on shop in 4 s.");
  });

  it("an env value is not kept after a refusal either", async () => {
    const VAL = "never-kept-2";
    const f = fake(server(() => json(400, { error: { code: "bad_request", message: "value: one line of text" } })));
    const a = new Actions(f.env);
    const states: string[] = [];
    a.subscribe(() => states.push(JSON.stringify(a.all())));
    a.open(H, A, "env-set"); await flush();
    await a.send(H, A, VAL, { key: "K" }); await flush();
    expect(a.get(H, A).dialog?.error).toBe("Set variable refused: value: one line of text.");
    for (const s of [...states, ...f.writes]) expect(s).not.toContain(VAL);
  });
});

describe("outcome mapping (server truth)", () => {
  const o = (p: Partial<NonNullable<ActionRecord["outcome"]>>) => ({ checked_at: "x", verdict: "ok" as const, summary: "", ...p });
  it("succeeded", () => {
    expect(endView(endRec({ action: "rollback", outcome: o({ history: { at: 1, release: "20261113-171103", kind: "rollback", result: "ok", total_s: 1.5 } }) }))).toMatchObject({ kind: "ok", line: "Rolled back to 20261113-171103 in 1.5 s." });
    expect(endView(endRec({ action: "stop" })).line).toBe("Stopped shop in 4 s.");
    expect(endView(endRec({ action: "start" })).line).toBe("Started shop in 4 s.");
    expect(endView(endRec({ action: "restart" })).line).toBe("Restarted shop in 4 s.");
    expect(endView(endRec({ action: "deploy", outcome: o({ release: "r1", summary: "no new deploy on the server; shop is running" }) })).line).toBe("Deployed in 4 s: nothing new, r1 stays live.");
  });
  it("failed: the reason in one line and the next step", () => {
    const v = endView(rec({ action: "deploy", status: "failed", ended_at: "2026-11-21T14:03:00Z", exit: 1, message: "tando: preflight: health check got 502; deploy of 20261121-140233: failed; shop is running on 20261120-101010",
      outcome: o({ verdict: "failed", release: "20261120-101010" }) }));
    expect(v).toMatchObject({ kind: "fail", badge: "failed", showLog: true });
    expect(v.line).toBe("Deploy failed: tando: preflight: health check got 502; deploy of 20261121-140233: failed; shop is running on 20261120-101010.");
    expect(v.next).toBe("The live release is 20261120-101010. See the log, fix, then try again.");
    const b = endView(rec({ status: "failed", code: "busy", message: "busy: shop is busy: a deploy is running" }));
    expect(b.line).toBe("Restart did not run: shop is busy: a deploy is running.");
    expect(b.showLog).toBe(false);
  });
  it("unknown", () => {
    const v = endView(rec({ action: "env-set", status: "unknown", message: "the server did not say how it ended; tando status and tando history show it" }));
    expect(v).toMatchObject({ kind: "stale", badge: "unknown" });
    expect(v.line).toBe("Not known how the variable change ended: the server did not say how it ended; tando status and tando history show it.");
  });
});

describe("confirmation copy", () => {
  it("names the action, app and server and says what happens", () => {
    expect(dialogCopy("deploy", "vps", "shop", { origin: "alice@laptop:/src/shop" })).toEqual({
      title: "Deploy shop to vps?", body: "Builds /src/shop on this Mac and deploys it to vps. The live release stays until the new one is healthy.", button: "Deploy", destructive: false });
    expect(dialogCopy("rollback", H, A, { target: "20261113-171103", live: "20261121-140233" })).toEqual({
      title: "Roll back shop on web-1?", body: "shop switches to release 20261113-171103 and 20261121-140233 stops being live. Nothing is removed; deploy again to return.", button: "Roll back", destructive: true });
    expect(dialogCopy("rollback", H, A, { release: "20261110-000000", target: "x" }).body).toContain("release 20261110-000000");
    expect(dialogCopy("restart", H, A, { live: "r1" })).toEqual({ title: "Restart shop on web-1?", body: "shop restarts on its live release r1. Requests may fail for a few seconds.", button: "Restart", destructive: false });
    expect(dialogCopy("stop", H, A)).toEqual({ title: "Stop shop on web-1?", body: "Visitors get 503 until you start it. Jobs and workers stop too. Nothing is removed.", button: "Stop", destructive: true });
    expect(dialogCopy("start", H, A, { live: "r1" })).toEqual({ title: "Start shop on web-1?", body: "shop starts on its live release r1, with its jobs and workers.", button: "Start", destructive: false });
    expect(dialogCopy("env-set", H, A)).toEqual({ title: "Set a variable of shop on web-1?", body: "shop restarts once with the new value. If it does not come up healthy, nothing changes.", button: "Set variable", destructive: false });
  });
  it("only Roll back and Stop are destructive", () => {
    const d = (["deploy", "rollback", "restart", "stop", "start", "env-set"] as const).filter((x) => dialogCopy(x, H, A).destructive);
    expect(d).toEqual(["rollback", "stop"]);
  });
  it("shows the command", () => {
    expect(commandFor("deploy", H, A)).toBe("tando deploy -a shop -H web-1");
    expect(commandFor("rollback", H, A, { release: "20261113-171103" })).toBe("tando rollback shop 20261113-171103 -H web-1");
    expect(commandFor("env-set", H, A, { key: "API_TOKEN" })).toBe("tando env set API_TOKEN -a shop -H web-1");
    expect(commandFor("stop", H, A)).toBe("tando stop shop -H web-1");
  });
  it("refusals and no exclamation marks or 'successfully'", () => {
    expect(refusedLine("deploy", "no record.")).toBe("Deploy refused: no record.");
    const all = (["deploy", "rollback", "restart", "stop", "start", "env-set"] as const).map((x) => JSON.stringify(dialogCopy(x, H, A))).join();
    expect(all).not.toMatch(/!|successfully|please/i);
  });
});

describe("disabled deploy", () => {
  it("no origin record: the reason, by tando-dash's rule", () => {
    expect(deployBlocked(A, "vps", null, "alice@mac")).toBe("tando has no record of where shop was deployed from. Deploy it once from its folder with tando deploy -H vps.");
    expect(deployBlocked(A, "vps", "", "alice@mac")).not.toBeNull();
  });
  it("another machine's record", () => {
    expect(deployBlocked(A, "vps", "bob@box:/home/bob/shop", "alice@mac")).toBe("shop was last deployed from bob@box, not from this machine (alice@mac). Deploy from there.");
  });
  it("this machine's record: allowed (tando-dash checks the folder itself)", () => {
    expect(deployBlocked(A, "vps", "alice@mac:/src/shop", "alice@mac")).toBeNull();
  });
});

describe("env set fields", () => {
  it("key: tando's name rule", () => {
    expect(envKeyError("API_TOKEN")).toBeNull();
    expect(envKeyError("_x1")).toBeNull();
    expect(envKeyError("1X")).not.toBeNull();
    expect(envKeyError("A-B")).not.toBeNull();
    expect(envKeyError("")).toBe("Enter a name.");
  });
  it("value: one line, 32 KB, and the error never repeats it", () => {
    expect(envValueError("abc def")).toBeNull();
    expect(envValueError("a\nb")).toBe("One line of text: no line breaks or control characters.");
    expect(envValueError("x".repeat(32 * 1024 + 1))).toBe("32 KB at most.");
  });
});

describe("SSE parsing", () => {
  it("splits events across chunks, keeps ids, skips comments", async () => {
    const enc = new TextEncoder();
    const body = new ReadableStream<Uint8Array>({ start(c) { [": hi\n\nretry: 3000\n\nid: 1\nevent: li", "ne\ndata: {\"n\":1}\n", "\nevent: end\ndata: {}\n\n"].forEach((x) => c.enqueue(enc.encode(x))); c.close(); } });
    const got: unknown[] = [];
    await readSse(body, (e) => got.push(e));
    expect(got).toEqual([{ event: "line", data: "{\"n\":1}", id: "1" }, { event: "end", data: "{}", id: null }]);
  });
});

describe("panel header", () => {
  it("running, then ended", () => {
    const o = { action: "rollback", app: "shop", startedAt: "2026-11-21T14:02:00Z" };
    expect(runningLine(o, Date.parse("2026-11-21T14:02:32Z"))).toBe("Rolling back shop · started 14:02 GMT · 32 s");
    expect(runningLine(o, Date.parse("2026-11-21T14:02:32Z"), true)).toBe("Rollback of shop · started 14:02 GMT · 32 s");
    expect(runningLine({ ...o, action: "deploy" }, Date.parse("2026-11-21T14:02:48Z"), true)).toBe("Deploy of shop · started 14:02 GMT · 48 s");
  });
});
