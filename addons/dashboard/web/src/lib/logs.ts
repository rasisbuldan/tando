// Logs: line parsing, filters, the follow state machine over EventSource, and a bounded buffer.
// Nothing here is written to any browser storage: lines live in memory only.
import { qs } from "./api";

export const BUFFER_MAX = 5000; // DESIGN 6: ring buffer in memory
export const TAIL_N = 200;      // last 200 lines on open

export type LevelWord = "err" | "wrn" | "inf" | "dbg";
export interface LogLine {
  id: number; usec: number; t: number; // t: unix seconds (GMT shown by the page)
  level: LevelWord; worker: string | null; unit: string; src: string; msg: string;
}
export interface RawLogLine { time?: string; usec?: number | string; src?: string; unit?: string; priority?: number | string; level?: string; msg?: string }

/** journal priority (0-7) or the CLI's level word -> the 3-letter word the viewer shows */
export function levelWord(priority: unknown, level: unknown): LevelWord {
  const p = typeof priority === "string" && priority !== "" ? Number(priority) : priority;
  if (typeof p === "number" && Number.isFinite(p)) return p <= 3 ? "err" : p === 4 ? "wrn" : p <= 6 ? "inf" : "dbg";
  switch (typeof level === "string" ? level.toLowerCase() : "") {
    case "emerg": case "alert": case "crit": case "err": case "error": return "err";
    case "warning": case "warn": return "wrn";
    case "debug": return "dbg";
    default: return "inf";
  }
}

/** units are tando-<app>.service, tando-<app>_worker-<name>.service, tando-<app>_job-<name>.service */
export function workerOf(unit: string | undefined): string | null {
  const m = /_worker-([a-z][a-z0-9-]*)(?:\.service)?$/.exec(unit ?? "");
  return m ? m[1] : null;
}

let seq = 0;
/** one CLI JSON line -> a viewer line; null when it is not a log line */
export function parseLine(raw: unknown, id?: number): LogLine | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as RawLogLine;
  if (typeof r.msg !== "string") return null;
  const usec = Number(r.usec);
  const u = Number.isFinite(usec) ? usec : 0;
  return {
    id: id ?? ++seq, usec: u, t: Math.floor(u / 1e6), level: levelWord(r.priority, r.level),
    worker: workerOf(r.unit), unit: r.unit ?? "", src: r.src ?? "", msg: r.msg,
  };
}
export function parseLines(raws: unknown[]): LogLine[] {
  const out: LogLine[] = [];
  for (const r of raws) { const l = parseLine(r); if (l) out.push(l); }
  return out;
}

export interface LogFilters { level: string; text: string; worker: string; release: string }
export const NO_FILTERS: LogFilters = { level: "", text: "", worker: "", release: "" };
export const LEVELS = ["err", "warning", "notice", "info", "debug"] as const;

const NAME = /^[a-z][a-z0-9-]*$/;
/** a text filter tando-dash accepts: 1-256 chars, no control characters, not starting with "-" */
export function validText(t: string): boolean { return t.length >= 1 && t.length <= 256 && !/[\u0000-\u001f\u007f]/.test(t) && !t.startsWith("-"); }

/** /api/logs query for the one-shot tail; invalid text is left out (and reported by textProblem) */
export function tailQuery(host: string, app: string, f: LogFilters, n = TAIL_N): string {
  return qs({
    host, app, n: String(n), level: f.level || undefined, grep: validText(f.text) ? f.text : undefined,
    worker: NAME.test(f.worker) ? f.worker : undefined, release: f.release || undefined,
  });
}
/** /api/logs/stream takes level and worker only; text is matched in the page, a release cannot follow */
export function streamQuery(host: string, app: string, f: LogFilters): string {
  return qs({ host, app, level: f.level || undefined, worker: NAME.test(f.worker) ? f.worker : undefined });
}
export function textProblem(t: string): string | null {
  if (!t) return null;
  if (t.startsWith("-")) return "A filter cannot start with “-”.";
  if (t.length > 256) return "A filter is at most 256 characters.";
  return validText(t) ? null : "A filter cannot hold control characters.";
}
/** the page-side match for a follow (case-insensitive, fixed text) */
export function matchText(l: LogLine, text: string): boolean { return !text || l.msg.toLowerCase().includes(text.toLowerCase()); }
export function filterLines(lines: LogLine[], text: string): LogLine[] { return text ? lines.filter((l) => matchText(l, text)) : lines; }

/** distinct workers seen in the lines plus the chosen one, sorted */
export function workersIn(lines: LogLine[], chosen: string): string[] {
  const s = new Set<string>(chosen ? [chosen] : []);
  for (const l of lines) if (l.worker) s.add(l.worker);
  return [...s].sort();
}

/** appends keeping the newest `max` lines */
export function appendLines(buf: LogLine[], add: LogLine[], max = BUFFER_MAX): LogLine[] {
  if (add.length === 0) return buf;
  const out = buf.length + add.length > max ? buf.concat(add).slice(-max) : buf.concat(add);
  return out;
}

// ---- wrapped row heights (virtualised list with fixed-height rows, DESIGN 6) ----
export const ROW_H = 18;
export const CHAR_W = 7.5; // 12.5 px monospace
/** columns of message text that fit a row of `width` px next to time/level/worker columns */
export function msgCols(width: number, hasWorker: boolean): number {
  const fixed = 8 * CHAR_W + 3 * CHAR_W + (hasWorker ? 10 * CHAR_W : 0) + 3 * 8 + 16;
  return Math.max(20, Math.floor((width - fixed) / CHAR_W));
}
/** row heights and their prefix sums: the offset of row i is offs[i], the total offs[n] */
export function rowOffsets(lines: LogLine[], wrapAll: boolean, expanded: ReadonlySet<number>, cols: number): number[] {
  const offs = new Array<number>(lines.length + 1);
  offs[0] = 0;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    const rows = wrapAll || expanded.has(l.id) ? Math.max(1, Math.ceil(l.msg.length / cols)) : 1;
    offs[i + 1] = offs[i] + rows * ROW_H;
  }
  return offs;
}
/** the rows to draw for a scroll window, with `over` extra rows each side */
export function visibleRange(offs: number[], top: number, height: number, over = 6): { start: number; end: number } {
  const n = offs.length - 1;
  if (n <= 0) return { start: 0, end: 0 };
  let lo = 0, hi = n - 1;
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (offs[mid] <= top) lo = mid; else hi = mid - 1; }
  let end = lo;
  while (end < n && offs[end] < top + height) end++;
  return { start: Math.max(0, lo - over), end: Math.min(n, end + over) };
}

// ---- follow: EventSource state machine ----
export type EndReason = "error" | "dropped" | "busy" | "ended" | "lost";
export type FollowState =
  | { kind: "idle" }
  | { kind: "connecting" }
  | { kind: "live" }
  | { kind: "reconnecting"; attempt: number; retryInMs: number | null }
  | { kind: "stopped"; reason: EndReason; message: string };

export interface ESLike {
  readyState: number;
  addEventListener(type: string, fn: (e: { data?: string }) => void): void;
  close(): void;
}
export type ESFactory = (url: string) => ESLike;
export const ES_CONNECTING = 0, ES_CLOSED = 2;

/** one-line state, what to do next (copy rules 5, 14) */
export function followLine(s: FollowState): string {
  switch (s.kind) {
    case "idle": return "Not following.";
    case "connecting": return "Connecting…";
    case "live": return "Following live.";
    case "reconnecting": return `Connection lost, reconnecting (attempt ${s.attempt}). Lines in the gap are filled in.`;
    case "stopped": return s.message;
  }
}

export function stoppedMessage(reason: EndReason, server?: string): string {
  switch (reason) {
    case "dropped": return "Stopped: this tab could not keep up with the log. Resume to follow again.";
    case "busy": return "Stopped: the server's log sessions are all taken. Resume in a moment.";
    case "ended": return "Stopped: the log source failed several times in a row. Check the app, then resume.";
    case "lost": return "Stopped: lost the connection to tando-dash. Resume to follow again.";
    default: return `Stopped: ${server || "the log stream reported an error"}. Resume to follow again.`;
  }
}

export interface FollowHandlers {
  onState: (s: FollowState) => void;
  /** a batch of lines; the page appends them once per animation frame */
  onLines: (lines: LogLine[]) => void;
}
export interface FollowEnv { schedule: (f: () => void) => unknown; cancel: (h: unknown) => void }
export const frameEnv: FollowEnv = {
  schedule: (f) => (typeof requestAnimationFrame === "function" ? requestAnimationFrame(f) : setTimeout(f, 16)),
  cancel: (h) => (typeof cancelAnimationFrame === "function" ? cancelAnimationFrame(h as number) : clearTimeout(h as ReturnType<typeof setTimeout>)),
};

/**
 * Follows /api/logs/stream. The browser reconnects an EventSource by itself, which is wanted for a
 * dropped network (the server resumes from Last-Event-ID) and not after `error` or `dropped`: those
 * are the server's last event, so the source is closed here and the page shows Resume.
 */
export class LogFollow {
  private es: ESLike | null = null;
  private pending: LogLine[] = [];
  private frame: unknown = null;
  private attempt = 0;
  private state: FollowState = { kind: "idle" };
  constructor(private url: string, private make: ESFactory, private h: FollowHandlers, private env: FollowEnv = frameEnv) {}

  get current(): FollowState { return this.state; }
  private set(s: FollowState) { this.state = s; this.h.onState(s); }

  start() {
    if (this.es) return;
    this.set({ kind: "connecting" });
    const es = this.make(this.url);
    this.es = es;
    const on = (t: string, f: (d: unknown) => void) => es.addEventListener(t, (e) => { if (this.es === es) f(parseData(e.data)); });
    on("hello", () => { this.attempt = 0; this.set({ kind: "live" }); });
    on("line", (d) => {
      const l = parseLine(d, undefined);
      if (!l) return;
      if (this.state.kind !== "live") this.set({ kind: "live" });
      this.pending.push(l);
      if (this.frame == null) this.frame = this.env.schedule(() => this.flush());
    });
    on("heartbeat", () => { /* keeps the line open; nothing to show */ });
    on("reconnecting", (d) => {
      const o = (d ?? {}) as { attempt?: number; retry_in_ms?: number };
      this.attempt = o.attempt ?? this.attempt + 1;
      this.set({ kind: "reconnecting", attempt: this.attempt, retryInMs: o.retry_in_ms ?? null });
    });
    on("reconnected", () => { this.attempt = 0; this.set({ kind: "live" }); });
    on("dropped", () => this.end("dropped"));
    on("busy", () => this.end("busy"));
    // the server's `error` event carries {code, message}; the browser's own error event carries nothing
    es.addEventListener("error", (e) => {
      if (this.es !== es) return;
      if (e && typeof e.data === "string" && e.data !== "") {
        const o = (parseData(e.data) ?? {}) as { code?: string; message?: string };
        this.end(o.code === "busy" ? "busy" : o.code === "ended" ? "ended" : "error", o.message);
      } else if (es.readyState === ES_CLOSED) {
        this.end("lost");
      } else {
        this.set({ kind: "reconnecting", attempt: ++this.attempt, retryInMs: null }); // the browser retries by itself
      }
    });
  }

  private end(reason: EndReason, message?: string) {
    this.flush();
    this.close();
    this.set({ kind: "stopped", reason, message: stoppedMessage(reason, message) });
  }
  private flush() {
    if (this.frame != null) { this.env.cancel(this.frame); this.frame = null; }
    if (this.pending.length) { const b = this.pending; this.pending = []; this.h.onLines(b); }
  }
  /** leave: closes the source, drops what was not yet delivered; no further events */
  stop() { this.close(); this.pending = []; if (this.frame != null) { this.env.cancel(this.frame); this.frame = null; } }
  private close() { const es = this.es; this.es = null; es?.close(); }
}

function parseData(s: string | undefined): unknown { if (!s) return null; try { return JSON.parse(s); } catch { return null; } }
