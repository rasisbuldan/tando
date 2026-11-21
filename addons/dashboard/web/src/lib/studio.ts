// The database studio from the sidebar and the app header (docs/SPEC.md "Database studio"):
// confirm every open (a token of kind "studio"), POST /api/studio/open with one Idempotency-Key
// per user action, then the studio's own page opens in a window of its own. tando-dash allows one
// studio per server; which one is open comes with the overview poll (no poller of its own).
// The one-time link is held in this dialog's state only (never stored, never in a URL here).
// No React in here: tested with a fake fetch.

export interface OpenStudio { host: string; app: string; since: string; state: "starting" | "open" }
export type EntryState =
  | { kind: "closed" }
  | { kind: "opening" }
  | { kind: "open"; since: string }
  | { kind: "taken"; by: string }; // the server's dashboard studio is another app's

export interface StudioDialog {
  host: string; app: string;
  token: string | null; preparing: boolean;
  key: string | null; sending: boolean;
  error: string | null;
  url: string | null; // opened: the link (works once), for "Nothing opened?"
}

export interface StudioResp { status: number; json(): Promise<unknown> }
export interface StudioEnv {
  fetch: (url: string, init: { method: string; headers: Record<string, string>; body: string; credentials: "same-origin" }) => Promise<StudioResp>;
  open: (url: string) => void;
  uuid: () => string;
}

const oneLine = (s: string) => s.replace(/\s+/g, " ").trim().replace(/[.;:]+$/, "");

export function entryState(host: string, app: string, open: OpenStudio[], dialog: StudioDialog | null): EntryState {
  const o = open.find((s) => s.host === host);
  if (o && o.app === app) return o.state === "starting" ? { kind: "opening" } : { kind: "open", since: o.since };
  if (dialog && dialog.host === host && dialog.app === app && dialog.sending) return { kind: "opening" };
  if (o) return { kind: "taken", by: o.app };
  return { kind: "closed" };
}

export const studioCopy = (host: string, app: string) => ({
  title: `Open the database of ${app}?`,
  body: `Open a read-only SQL session on ${app} (${host})? It ends when you press Stop, after 30 min unused, or when the dashboard stops.`,
  command: `tando db studio ${app} -H ${host}`,
});

export class Studios {
  private list: OpenStudio[] = [];
  private dlg: StudioDialog | null = null;
  private subs = new Set<() => void>();
  private snap: { list: OpenStudio[]; dialog: StudioDialog | null } = { list: this.list, dialog: null };
  constructor(private env: StudioEnv) {}

  get = () => this.snap;
  subscribe = (f: () => void): (() => void) => { this.subs.add(f); return () => { this.subs.delete(f); }; };
  private emit() { this.snap = { list: this.list, dialog: this.dlg }; this.subs.forEach((f) => f()); }
  private patch(p: Partial<StudioDialog>) { if (this.dlg) { this.dlg = { ...this.dlg, ...p }; this.emit(); } }

  /** the overview's `studios` */
  fromOverview(l: unknown) {
    const ok = Array.isArray(l) ? l.filter((x): x is OpenStudio => !!x && typeof x.host === "string" && typeof x.app === "string") : [];
    this.list = ok;
    this.emit();
  }

  private async post(path: string, body: unknown, headers: Record<string, string> = {}) {
    const r = await this.env.fetch(path, { method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json", Accept: "application/json", ...headers }, body: JSON.stringify(body) });
    let b: Record<string, unknown> | null = null;
    try { b = (await r.json()) as Record<string, unknown>; } catch { /* not JSON */ }
    return { status: r.status, body: b };
  }

  /** the confirmation; its token is asked for at once */
  async ask(host: string, app: string) {
    this.dlg = { host, app, token: null, preparing: true, key: null, sending: false, error: null, url: null };
    this.emit();
    const d0 = this.dlg;
    let tok: string | null = null, err: string | null = null;
    try {
      const r = await this.post("/api/confirm", { action: "studio", host, app });
      if (typeof r.body?.token === "string") tok = r.body.token;
      else err = `Could not prepare this: ${oneLine((r.body?.error as { message?: string } | undefined)?.message ?? `tando-dash answered ${r.status}`)}. Close and try again.`;
    } catch { err = "Could not prepare this: tando-dash did not answer. Close and try again."; }
    if (this.dlg?.host !== d0.host || this.dlg.app !== d0.app || this.dlg.token) return;
    this.patch({ token: tok, preparing: false, error: err });
  }

  close() { if (this.dlg && !this.dlg.sending) { this.dlg = null; this.emit(); } }

  /** Open: start the studio, then its page in a new window (window.open, "noopener") */
  async confirm() {
    const d = this.dlg;
    if (!d || d.sending || d.url) return;
    const key = d.key ?? this.env.uuid();
    this.patch({ key, sending: true, error: null });
    let r: { status: number; body: Record<string, unknown> | null };
    try {
      r = await this.post("/api/studio/open", { host: d.host, app: d.app, confirm: d.token ?? "" }, { "Idempotency-Key": key });
    } catch {
      this.patch({ sending: false, error: "tando-dash did not answer. Open again to retry (it will not start a second studio)." });
      return;
    }
    const url = typeof r.body?.url === "string" && /^http:\/\/127\.0\.0\.1:\d+\/#c=[A-Za-z0-9_-]+$/.test(r.body.url) ? r.body.url : null;
    if (r.status === 200 && url) {
      this.list = [...this.list.filter((s) => s.host !== d.host), { host: d.host, app: d.app, since: String(r.body?.since ?? ""), state: "open" }];
      this.patch({ sending: false, url });
      this.env.open(url);
      return;
    }
    const e = r.body?.error as { code?: string; message?: string } | undefined;
    // a refusal is final for this token: a new Open asks again
    this.patch({ sending: false, key: null, token: null, error: oneLine(e?.message ?? `tando-dash answered ${r.status}`) + "." });
    if (e?.code === "confirm" || r.status >= 500) void this.reToken();
  }

  private async reToken() {
    const d = this.dlg;
    if (!d) return;
    try {
      const r = await this.post("/api/confirm", { action: "studio", host: d.host, app: d.app });
      if (typeof r.body?.token === "string" && this.dlg === this.snap.dialog && this.dlg?.host === d.host) this.patch({ token: r.body.token });
    } catch { /* the error line stays */ }
  }

  /** Stop: the dashboard's child ends (the CLI ends its session) */
  async stop(host: string, app: string): Promise<string | null> {
    try {
      const r = await this.post("/api/studio/stop", { host, app });
      if (r.status === 200) {
        this.list = this.list.filter((s) => !(s.host === host && s.app === app));
        this.emit();
        return null;
      }
      return oneLine((r.body?.error as { message?: string } | undefined)?.message ?? `tando-dash answered ${r.status}`);
    } catch { return "tando-dash did not answer"; }
  }
}

let inst: Studios | null = null;
export function studios(): Studios {
  if (!inst) inst = new Studios({
    fetch: (u, i) => fetch(u, i),
    open: (u) => { window.open(u, "_blank", "noopener"); },
    uuid: () => (crypto.randomUUID ? crypto.randomUUID() : `k-${Date.now()}-${Math.random().toString(36).slice(2)}`),
  });
  return inst;
}
