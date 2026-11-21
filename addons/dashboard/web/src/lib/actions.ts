// Writes (DESIGN sections 6 and 7, SPEC "Idempotency, failure handling, robustness"): the
// confirmation dialog's token, one Idempotency-Key per user action kept until it ends, the
// progress stream with Last-Event-ID resume, the server's outcome, and reattaching after a
// reload. No React in here: tested with fakes for fetch, storage and the clock.
//
// sessionStorage holds only {key, host, app, action} of the writes this tab started or watches;
// an env value is never in the state, the storage, a URL or an error line: it is an argument of
// send() and goes straight into the request body.
import { sessionStore } from "./api";
import { backoffMs } from "./poller";

export type ActionName = "deploy" | "rollback" | "stop" | "start" | "restart" | "env-set";
export interface ActionParams { release?: string; key?: string }
export interface Running { action: string; since: string; key: string }
export interface HistEntry { at: number; release: string; kind: string; result: string; total_s?: number; note?: string }
export interface Outcome { checked_at: string; state?: string; release?: string; history?: HistEntry; verdict: "ok" | "failed" | "unknown"; summary: string }
export interface ActionRecord {
  key: string; action: string; host: string; app: string; status: "running" | "done" | "failed" | "unknown";
  started_at: string; ended_at?: string; exit?: number; code?: string; message?: string; outcome?: Outcome; replay?: boolean; output?: string;
}

export interface DialogState {
  action: ActionName; params: ActionParams;
  token: string | null; preparing: boolean; tokenError: string | null;
  key: string | null;         // this user action's Idempotency-Key, from the first send until it is answered
  sending: boolean;
  sendFailed: boolean;        // the last send got no answer: Retry sends the same key
  error: string | null;       // refused: one line
  conflict: Running | null;   // 409: what runs and since when
}
export interface OpState {
  key: string; action: string; host: string; app: string; startedAt: string | null;
  lines: string[]; lastId: number; dropped: number;
  status: ActionRecord["status"]; record: ActionRecord | null;
  replay: boolean; reattached: boolean; watching: boolean; // watching: another request's write (409 "Show progress")
  streamError: string | null; varName: string | null;
}
export interface Slot { dialog: DialogState | null; op: OpState | null }
const EMPTY: Slot = { dialog: null, op: null };

export interface Resp { ok: boolean; status: number; json(): Promise<unknown>; body?: ReadableStream<Uint8Array> | null }
export interface ActionEnv {
  fetch: (url: string, init: { method: string; headers: Record<string, string>; body?: string; signal?: AbortSignal; credentials: "same-origin" }) => Promise<Resp>;
  storage: Pick<Storage, "getItem" | "setItem" | "removeItem"> | null;
  uuid: () => string;
  now: () => number;
  rand: () => number;
  setTimeout: (f: () => void, ms: number) => unknown;
  clearTimeout: (h: unknown) => void;
}

export const STORE_KEY = "tando-dash:writes";
export const MAX_LINES = 2000;
export const TOKEN_WAIT_MS = 2000;
const SEND_TIMEOUT_MS = 15000;
interface Stored { key: string; host: string; app: string; action: string }

const slotKey = (host: string, app: string) => `${host}/${app}`;
const oneLine = (s: string) => s.replace(/\s+/g, " ").trim().replace(/[.;:]+$/, "");

export class Actions {
  private slots = new Map<string, Slot>();
  private subs = new Set<() => void>();
  private streams = new Map<string, AbortController>(); // by write key
  private gen = new Map<string, number>();              // dialog generation: a late token for a closed dialog is dropped
  constructor(private env: ActionEnv) {}

  get = (host: string, app: string): Slot => this.slots.get(slotKey(host, app)) ?? EMPTY;
  subscribe = (f: () => void): (() => void) => { this.subs.add(f); return () => { this.subs.delete(f); }; };
  /** every write this page knows of, for "a write is running" elsewhere */
  all = (): Slot[] => [...this.slots.values()];

  private put(host: string, app: string, p: Partial<Slot>) {
    const k = slotKey(host, app);
    this.slots.set(k, { ...(this.slots.get(k) ?? EMPTY), ...p });
    this.subs.forEach((f) => f());
  }
  private dlg(host: string, app: string, p: Partial<DialogState>) {
    const d = this.get(host, app).dialog;
    if (d) this.put(host, app, { dialog: { ...d, ...p } });
  }
  private opPatch(host: string, app: string, key: string, p: Partial<OpState> | ((o: OpState) => Partial<OpState>)) {
    const o = this.get(host, app).op;
    if (!o || o.key !== key) return;
    this.put(host, app, { op: { ...o, ...(typeof p === "function" ? p(o) : p) } });
  }

  // ---- storage: keys and apps only ----
  private stored(): Stored[] {
    try { const v = JSON.parse(this.env.storage?.getItem(STORE_KEY) ?? "[]"); return Array.isArray(v) ? v.filter((x) => x && typeof x.key === "string") : []; } catch { return []; }
  }
  private remember(s: Stored) {
    const all = this.stored().filter((x) => x.key !== s.key && !(x.host === s.host && x.app === s.app));
    all.push({ key: s.key, host: s.host, app: s.app, action: s.action });
    try { this.env.storage?.setItem(STORE_KEY, JSON.stringify(all.slice(-20))); } catch { /* private mode: no reattach */ }
  }
  private forget(key: string) {
    const all = this.stored().filter((x) => x.key !== key);
    try { if (all.length) this.env.storage?.setItem(STORE_KEY, JSON.stringify(all)); else this.env.storage?.removeItem(STORE_KEY); } catch { /* */ }
  }

  private async post(path: string, body: unknown, headers: Record<string, string> = {}, timeoutMs = SEND_TIMEOUT_MS): Promise<{ status: number; body: Record<string, unknown> | null }> {
    const ctl = new AbortController();
    const h = this.env.setTimeout(() => ctl.abort(), timeoutMs);
    try {
      const r = await this.env.fetch(path, { method: "POST", credentials: "same-origin", signal: ctl.signal,
        headers: { "Content-Type": "application/json", Accept: "application/json", ...headers }, body: JSON.stringify(body) });
      let b: Record<string, unknown> | null = null;
      try { b = (await r.json()) as Record<string, unknown>; } catch { /* not JSON */ }
      if (r.status === 401 && (b?.error as { code?: string } | undefined)?.code === "session") sessionStore.end();
      return { status: r.status, body: b };
    } finally { this.env.clearTimeout(h); }
  }

  // ---- the confirmation dialog ----

  /** open the dialog; the confirm token is asked for at once */
  open(host: string, app: string, action: ActionName, params: ActionParams = {}) {
    const o = this.get(host, app).op;
    if (o && o.status === "running") return; // the buttons are disabled; never a second write from here
    this.put(host, app, { dialog: { action, params, token: null, preparing: true, tokenError: null, key: null, sending: false, sendFailed: false, error: null, conflict: null } });
    void this.token(host, app);
  }

  private async token(host: string, app: string): Promise<string | null> {
    const k = slotKey(host, app);
    const g = (this.gen.get(k) ?? 0) + 1;
    this.gen.set(k, g);
    const d = this.get(host, app).dialog;
    if (!d) return null;
    this.dlg(host, app, { token: null, preparing: true, tokenError: null });
    let tok: string | null = null, err: string | null = null;
    try {
      const r = await this.post("/api/confirm", { action: d.action, host, app }, {}, TOKEN_WAIT_MS);
      const e = r.body?.error as { message?: string } | undefined;
      if (typeof r.body?.token === "string") tok = r.body.token;
      else err = `Could not prepare this: ${oneLine(e?.message ?? `tando-dash answered ${r.status}`)}. Close and try again.`;
    } catch {
      err = "Could not prepare this: tando-dash did not answer in 2 s. Close and try again.";
    }
    if (this.gen.get(k) !== g || !this.get(host, app).dialog) return null;
    this.dlg(host, app, { token: tok, preparing: false, tokenError: err });
    return tok;
  }

  cancel(host: string, app: string) {
    const d = this.get(host, app).dialog;
    if (!d || d.sending) return;
    if (d.key) this.forget(d.key); // never answered: a reload finds nothing to reattach to (or the server's 404)
    this.gen.set(slotKey(host, app), (this.gen.get(slotKey(host, app)) ?? 0) + 1);
    this.put(host, app, { dialog: null });
  }

  /** confirm: send the write. `value` is env-set's value: used for this request's body only. */
  async send(host: string, app: string, value?: string, extra: ActionParams = {}): Promise<void> {
    const d0 = this.get(host, app).dialog;
    if (!d0 || d0.sending || d0.conflict) return; // a double click sends once
    if (!d0.token && !d0.sendFailed) return;     // still preparing
    const params = { ...d0.params, ...extra };
    const key = d0.key ?? this.env.uuid();       // one key per user action; a retry reuses it
    this.dlg(host, app, { sending: true, key, params, error: null });
    this.remember({ key, host, app, action: d0.action });
    let conf = d0.token;
    if (d0.sendFailed || !conf) conf = await this.token(host, app); // (the old one may have been used)
    if (!this.get(host, app).dialog) return;
    const body: Record<string, unknown> = { action: d0.action, host, app, confirm: conf ?? "" };
    if (d0.action === "rollback" && params.release) body.params = { release: params.release };
    if (d0.action === "env-set") body.params = { key: params.key ?? "", value: value ?? "" };
    let r: { status: number; body: Record<string, unknown> | null };
    try {
      r = await this.post("/api/action", body, { "Idempotency-Key": key });
    } catch {
      this.dlg(host, app, { sending: false, sendFailed: true, error: "Could not reach tando-dash. Retry sends the same request; it runs once." });
      return;
    }
    const b = r.body ?? {};
    const err = b.error as { code?: string; message?: string; running?: Running } | undefined;
    if (err) {
      this.forget(key); // a refusal is not remembered by tando-dash: a new attempt is a new action
      if (err.code === "running" && err.running) {
        this.dlg(host, app, { sending: false, sendFailed: false, key: null, conflict: err.running, error: null });
        return;
      }
      if (err.code === "session") { this.put(host, app, { dialog: null }); return; }
      this.dlg(host, app, { sending: false, sendFailed: false, key: null, error: refusedLine(d0.action, err.message ?? `tando-dash answered ${r.status}`) });
      void this.token(host, app); // confirm again (a deploy refused for its folder can be)
      return;
    }
    if (typeof b.key !== "string") {
      this.dlg(host, app, { sending: false, sendFailed: true, error: `tando-dash answered ${r.status} without a record. Retry sends the same request; it runs once.` });
      return;
    }
    const rec = b as unknown as ActionRecord;
    this.put(host, app, { dialog: null, op: newOp(rec, { replay: !!rec.replay, varName: d0.action === "env-set" ? params.key ?? null : null }) });
    this.follow(host, app, key);
  }

  /** 409 "Show progress": watch the write that runs */
  view(host: string, app: string, running: Running) {
    this.put(host, app, { dialog: null, op: newOp({ key: running.key, action: running.action, host, app, status: "running", started_at: running.since }, { watching: true }) });
    this.remember({ key: running.key, host, app, action: running.action });
    this.follow(host, app, running.key);
  }

  /** Close the panel (only after the end) */
  close(host: string, app: string) {
    const o = this.get(host, app).op;
    if (!o || o.status === "running") return;
    this.streams.get(o.key)?.abort();
    this.forget(o.key);
    this.put(host, app, { op: null });
  }

  /** after a reload: find this tab's writes by key and show them again */
  async reattach(): Promise<void> {
    for (const s of this.stored()) {
      if (this.get(s.host, s.app).op?.key === s.key) continue;
      let r;
      try {
        r = await this.env.fetch(`/api/action?key=${encodeURIComponent(s.key)}`, { method: "GET", credentials: "same-origin", headers: { Accept: "application/json" } });
      } catch { continue; } // tando-dash not answering: the entry stays for the next load
      if (r.status === 404) { this.forget(s.key); continue; } // never reached it, or older than 24 h
      if (!r.ok) continue;
      let rec: ActionRecord;
      try { rec = (await r.json()) as ActionRecord; } catch { continue; }
      if (!rec || typeof rec.key !== "string") continue;
      this.put(s.host, s.app, { op: newOp({ ...rec, output: undefined }, { reattached: rec.status === "running" }) });
      this.follow(s.host, s.app, s.key);
    }
  }

  // ---- the progress stream ----

  private follow(host: string, app: string, key: string) {
    if (this.streams.has(key)) return;
    const ctl = new AbortController();
    this.streams.set(key, ctl);
    void this.streamLoop(host, app, key, ctl.signal).finally(() => { if (this.streams.get(key) === ctl) this.streams.delete(key); });
  }

  private async streamLoop(host: string, app: string, key: string, signal: AbortSignal) {
    let failures = 0;
    while (!signal.aborted) {
      const o = this.get(host, app).op;
      if (!o || o.key !== key) return;
      const headers: Record<string, string> = { Accept: "text/event-stream" };
      if (o.lastId > 0) headers["Last-Event-ID"] = String(o.lastId);
      let ended = false, gotSome = false;
      try {
        const r = await this.env.fetch(`/api/action/stream?key=${encodeURIComponent(key)}`, { method: "GET", credentials: "same-origin", headers, signal });
        if (r.status === 404) {
          this.forget(key);
          this.opPatch(host, app, key, { status: "unknown", streamError: "tando-dash has no record of this write any more (records are kept 24 h). tando history shows how it ended." });
          return;
        }
        if (r.status === 401) { sessionStore.end(); return; }
        if (!r.ok || !r.body) throw new Error(`stream ${r.status}`);
        await readSse(r.body, (ev) => {
          gotSome = true;
          ended = this.onEvent(host, app, key, ev) || ended;
        });
      } catch { if (signal.aborted) return; }
      if (ended || signal.aborted) return;
      failures = gotSome ? 1 : failures + 1;
      this.opPatch(host, app, key, { streamError: failures > 1 ? "Lost the progress stream. Reconnecting; the write goes on." : null });
      await new Promise<void>((res) => this.env.setTimeout(res, backoffMs(failures, this.env.rand)));
    }
  }

  /** one event; true at the end */
  private onEvent(host: string, app: string, key: string, ev: SseEvent): boolean {
    let data: Record<string, unknown> = {};
    try { data = JSON.parse(ev.data) as Record<string, unknown>; } catch { return false; }
    if (ev.event === "hello") {
      this.opPatch(host, app, key, (o) => ({ action: String(data.action ?? o.action), startedAt: String(data.started_at ?? o.startedAt ?? ""), streamError: null }));
    } else if (ev.event === "line") {
      const n = Number(data.n), text = String(data.text ?? "");
      this.opPatch(host, app, key, (o) => {
        if (!(n > o.lastId)) return {}; // a resumed stream never repeats a line
        const lines = o.lines.length >= MAX_LINES ? o.lines.slice(o.lines.length - MAX_LINES + 1) : o.lines.slice();
        lines.push(text);
        return { lines, lastId: n, dropped: o.dropped + (o.lines.length >= MAX_LINES ? 1 : 0), streamError: null };
      });
    } else if (ev.event === "end") {
      const rec = data as unknown as ActionRecord;
      this.opPatch(host, app, key, { status: rec.status, record: rec, streamError: null });
      this.forget(key);
      return true;
    }
    return false;
  }
}

function newOp(rec: ActionRecord, p: Partial<OpState> = {}): OpState {
  const ended = rec.status !== "running";
  return {
    key: rec.key, action: rec.action, host: rec.host, app: rec.app, startedAt: rec.started_at ?? null,
    lines: [], lastId: 0, dropped: 0, status: rec.status, record: ended ? rec : null,
    replay: false, reattached: false, watching: false, streamError: null, varName: null, ...p,
  };
}

// ---- Server-Sent Events over fetch (so Last-Event-ID can be sent on a resume) ----
export interface SseEvent { event: string; data: string; id: string | null }
export async function readSse(body: ReadableStream<Uint8Array>, on: (e: SseEvent) => void): Promise<void> {
  const rd = body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  let ev = "message", data: string[] = [], id: string | null = null;
  const line = (l: string) => {
    if (l === "") { if (data.length) on({ event: ev, data: data.join("\n"), id }); ev = "message"; data = []; id = null; return; }
    if (l.startsWith(":")) return;
    const i = l.indexOf(":");
    const f = i < 0 ? l : l.slice(0, i);
    let v = i < 0 ? "" : l.slice(i + 1);
    if (v.startsWith(" ")) v = v.slice(1);
    if (f === "event") ev = v; else if (f === "data") data.push(v); else if (f === "id") id = v;
  };
  for (;;) {
    const { done, value } = await rd.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let j;
    while ((j = buf.search(/\r\n|\n|\r/)) >= 0) {
      const l = buf.slice(0, j);
      buf = buf.slice(j + (buf[j] === "\r" && buf[j + 1] === "\n" ? 2 : 1));
      line(l);
    }
  }
}

// ---- copy (DESIGN sections 7 and 9) ----
const VERB: Record<string, string> = { deploy: "Deploy", rollback: "Roll back", restart: "Restart", stop: "Stop", start: "Start", "env-set": "Set variable" };
const NOUN: Record<string, string> = { deploy: "deploy", rollback: "rollback", restart: "restart", stop: "stop", start: "start", "env-set": "variable change" };
const ING: Record<string, string> = { deploy: "Deploying", rollback: "Rolling back", restart: "Restarting", stop: "Stopping", start: "Starting", "env-set": "Setting a variable of" };
export const actionVerb = (a: string) => VERB[a] ?? a;
export const actionNoun = (a: string) => NOUN[a] ?? a;

export function refusedLine(action: string, message: string): string {
  return `${actionVerb(action)} refused: ${oneLine(message)}.`;
}

const hm = new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
const toS = (iso: string | null | undefined) => { const t = iso ? Date.parse(iso) : NaN; return Number.isNaN(t) ? null : t / 1000; };
export const gmt = (iso: string | null | undefined) => { const s = toS(iso); return s == null ? "—" : `${hm.format(s * 1000)} GMT`; };
function dur(s: number): string {
  if (s < 10 && s % 1 !== 0) return `${s.toFixed(1)} s`;
  s = Math.max(0, Math.round(s));
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60), r = s % 60;
  if (s < 3600) return r ? `${m} min ${r} s` : `${m} min`;
  return `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min`;
}

/** 409: "A rollback of shop is running, started 14:02 GMT (40 s ago)." */
export function conflictLine(app: string, r: Running, nowMs: number): string {
  const s = toS(r.since);
  const ago = s == null ? "" : ` (${Math.max(0, Math.round(nowMs / 1000 - s)) < 5 ? "just now" : `${dur(Math.round(nowMs / 1000 - s))} ago`})`;
  const n = actionNoun(r.action);
  return `${/^[aeiou]/.test(n) ? "An" : "A"} ${n} of ${app} is running, started ${gmt(r.since)}${ago}.`;
}

/** the panel's header while running: "Deploying shop · started 14:02 GMT · 32 s" */
export function runningLine(o: Pick<OpState, "action" | "app" | "startedAt">, nowMs: number, ended = false): string {
  const s = toS(o.startedAt);
  const what = ended ? `${actionVerb(o.action).replace(/^Set variable$/, "Variable change")} of ${o.app}`.replace(/^Roll back of/, "Rollback of") : `${ING[o.action] ?? o.action} ${o.app}`;
  return `${what} · started ${gmt(o.startedAt)}${s != null ? ` · ${dur(Math.max(0, Math.round(nowMs / 1000 - s)))}` : ""}`;
}

export type EndKind = "ok" | "fail" | "stale";
export interface EndView { kind: EndKind; badge: string; line: string; next: string | null; showLog: boolean }
/** the end state from the server's record (never from an HTTP status) */
export function endView(rec: ActionRecord, varName: string | null = null): EndView {
  const a = rec.action, app = rec.app, o = rec.outcome;
  const s0 = toS(rec.started_at), s1 = toS(rec.ended_at);
  const took = o?.history?.total_s ?? (s0 != null && s1 != null ? s1 - s0 : null);
  const inT = took != null ? ` in ${dur(took)}` : "";
  const rel = o?.history?.release ?? o?.release ?? "";
  if (rec.status === "done") {
    const line = a === "deploy" ? (o?.history ? `Deployed ${rel}${inT}.` : `Deployed${inT}: nothing new, ${rel || "the live release"} stays live.`)
      : a === "rollback" ? `Rolled back to ${rel}${inT}.`
      : a === "restart" ? `Restarted ${app}${inT}.`
      : a === "stop" ? `Stopped ${app}${inT}.`
      : a === "start" ? `Started ${app}${inT}.`
      : a === "env-set" ? `Set ${varName ?? "the variable"} on ${app}${inT}.`
      : `Done${inT}.`;
    return { kind: "ok", badge: "done", line, next: null, showLog: false };
  }
  if (rec.status === "failed") {
    const msg = oneLine(rec.message || o?.summary || `tando ${a} failed`);
    if (rec.code === "busy") {
      return { kind: "fail", badge: "failed", line: `${actionVerb(a)} did not run: ${msg.replace(/^busy:\s*/, "")}.`, next: "Another operation holds the app. Try again when it ends.", showLog: false };
    }
    const next = a === "deploy" || a === "rollback"
      ? (o?.release ? `The live release is ${o.release}. See the log, fix, then try again.` : "See the log, fix, then try again.")
      : a === "env-set" ? `Nothing was changed if ${app} did not restart healthy. tando env log ${app} shows it.`
      : "See the log, then try again.";
    return { kind: "fail", badge: "failed", line: `${actionVerb(a)} failed: ${msg}.`, next, showLog: true };
  }
  if (rec.status === "unknown") {
    return { kind: "stale", badge: "unknown", line: `Not known how the ${actionNoun(a)} ended: ${oneLine(rec.message || o?.summary || "the server did not say")}.`,
      next: `Check with tando status ${app} -H ${rec.host}.`, showLog: false };
  }
  return { kind: "stale", badge: "running", line: "", next: null, showLog: false };
}

// ---- what the buttons may do ----
export interface Origin { who: string; dir: string }
export function parseOrigin(o: string | null | undefined): Origin | null {
  if (!o) return null;
  const i = o.indexOf(":");
  return i < 0 ? { who: o, dir: "" } : { who: o.slice(0, i), dir: o.slice(i + 1) };
}
/** the deploy button's reason to be off, by tando-dash's rules (it checks the folder itself) */
export function deployBlocked(app: string, host: string, origin: string | null | undefined, client: string | null): string | null {
  const o = parseOrigin(origin);
  if (!o) return `tando has no record of where ${app} was deployed from. Deploy it once from its folder with tando deploy -H ${host}.`;
  if (client && o.who !== client) return `${app} was last deployed from ${o.who}, not from this machine (${client}). Deploy from there.`;
  return null;
}
export const ENV_KEY_RE = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/;
export function envKeyError(k: string): string | null {
  if (k === "") return "Enter a name.";
  return ENV_KEY_RE.test(k) ? null : "Letters, digits and _, not starting with a digit; 128 at most.";
}
/** one line of text, 32 KB at most (tando-dash refuses the rest before anything runs) */
export function envValueError(v: string): string | null {
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(v)) return "One line of text: no line breaks or control characters.";
  if (new TextEncoder().encode(v).length > 32 * 1024) return "32 KB at most.";
  return null;
}

/** the CLI equivalent shown in the dialog */
export function commandFor(action: ActionName, host: string, app: string, p: ActionParams = {}): string {
  switch (action) {
    case "deploy": return `tando deploy -a ${app} -H ${host}`;
    case "rollback": return `tando rollback ${app}${p.release ? ` ${p.release}` : ""} -H ${host}`;
    case "env-set": return `tando env set ${p.key || "KEY"} -a ${app} -H ${host}`;
    default: return `tando ${action} ${app} -H ${host}`;
  }
}

export interface DialogCopy { title: string; body: string; button: string; destructive: boolean }
/** the confirmation's words (DESIGN section 6 and copy rule 4) */
export function dialogCopy(action: ActionName, host: string, app: string, p: ActionParams & { origin?: string | null; target?: string | null; live?: string | null; mac?: boolean } = {}): DialogCopy {
  switch (action) {
    case "deploy": {
      const dir = parseOrigin(p.origin)?.dir || "its folder";
      return { title: `Deploy ${app} to ${host}?`, body: `Builds ${dir} on this ${p.mac === false ? "machine" : "Mac"} and deploys it to ${host}. The live release stays until the new one is healthy.`, button: "Deploy", destructive: false };
    }
    case "rollback": {
      const to = p.release ?? p.target;
      return { title: `Roll back ${app} on ${host}?`, body: `${app} switches to release ${to ?? "the rollback target"}${p.live ? ` and ${p.live} stops being live` : ""}. Nothing is removed; deploy again to return.`, button: "Roll back", destructive: true };
    }
    case "restart": return { title: `Restart ${app} on ${host}?`, body: `${app} restarts on its live release${p.live ? ` ${p.live}` : ""}. Requests may fail for a few seconds.`, button: "Restart", destructive: false };
    case "stop": return { title: `Stop ${app} on ${host}?`, body: "Visitors get 503 until you start it. Jobs and workers stop too. Nothing is removed.", button: "Stop", destructive: true };
    case "start": return { title: `Start ${app} on ${host}?`, body: `${app} starts on its live release${p.live ? ` ${p.live}` : ""}, with its jobs and workers.`, button: "Start", destructive: false };
    case "env-set": return { title: `Set a variable of ${app} on ${host}?`, body: `${app} restarts once with the new value. If it does not come up healthy, nothing changes.`, button: "Set variable", destructive: false };
  }
}

// ---- the page's one instance ----
const browserEnv = (): ActionEnv => ({
  fetch: (u, i) => fetch(u, i) as Promise<Resp>,
  storage: (() => { try { return typeof sessionStorage !== "undefined" ? sessionStorage : null; } catch { return null; } })(),
  uuid: () => (typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `${Date.now().toString(16)}-${Math.random().toString(16).slice(2)}-k`),
  now: () => Date.now(), rand: Math.random,
  setTimeout: (f, ms) => setTimeout(f, ms), clearTimeout: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
});
let inst: Actions | null = null;
export function actions(): Actions {
  if (!inst) inst = new Actions(browserEnv());
  return inst;
}
