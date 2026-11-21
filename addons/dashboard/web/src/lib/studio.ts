// The database studio from the sidebar, the app header and the server page (docs/SPEC.md
// "Database studio"): one click mints a fresh one-time link (POST /api/studio/open {host, app})
// and opens the studio's own page in a new tab, no dialog. The tab is opened on the click itself,
// before the request, so a pop-up blocker lets it through; it goes to the link when the answer
// comes (or is closed when it fails). The link is held in this function only: never stored,
// never put in a URL of ours. No React in here: tested with a fake fetch.

export interface Tab { go(url: string): void; close(): void }
export interface StudioResp { status: number; json(): Promise<unknown> }
export interface StudioEnv {
  fetch: (url: string, init: { method: string; headers: Record<string, string>; body: string; credentials: "same-origin" }) => Promise<StudioResp>;
  openTab: () => Tab | null;          // a blank tab, on the click; null when the browser refused it
  openUrl: (url: string) => boolean;  // after the answer, when no tab could be opened first
}
export interface StudioSnap { opening: string[]; error: string | null }

const oneLine = (s: string) => s.replace(/\s+/g, " ").trim().replace(/[.;:]+$/, "");
const LINK = /^http:\/\/127\.0\.0\.1:\d+\/#c=[A-Za-z0-9_-]+(&app=[a-z0-9-]+)?$/;
const key = (host: string, app: string) => `${host}/${app}`;

/** the server's "Database studio": its first app with a database (the studio's own list switches apps) */
export function studioTarget(apps: { app: string; database: string | null }[] | undefined): string | null {
  return apps?.find((a) => a.database)?.app ?? null;
}

export class Studios {
  private busy = new Set<string>();
  private err: string | null = null;
  private subs = new Set<() => void>();
  private snap: StudioSnap = { opening: [], error: null };
  constructor(private env: StudioEnv) {}

  get = () => this.snap;
  subscribe = (f: () => void): (() => void) => { this.subs.add(f); return () => { this.subs.delete(f); }; };
  private emit() { this.snap = { opening: [...this.busy], error: this.err }; this.subs.forEach((f) => f()); }
  dismiss() { if (this.err) { this.err = null; this.emit(); } }

  async open(host: string, app: string): Promise<void> {
    const k = key(host, app);
    if (this.busy.has(k)) return;
    const tab = this.env.openTab();
    this.busy.add(k);
    this.err = null;
    this.emit();
    let fail: string | null = null, url: string | null = null;
    try {
      const r = await this.env.fetch("/api/studio/open", { method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json", Accept: "application/json" }, body: JSON.stringify({ host, app }) });
      let b: Record<string, unknown> | null = null;
      try { b = (await r.json()) as Record<string, unknown>; } catch { /* not JSON */ }
      if (r.status === 200 && typeof b?.url === "string") {
        if (LINK.test(b.url)) url = b.url; else fail = "tando-dash answered with a link that is not the studio's. Not opened.";
      } else {
        fail = oneLine((b?.error as { message?: string } | undefined)?.message ?? `tando-dash answered ${r.status}`) + ".";
      }
    } catch {
      fail = "tando-dash did not answer. Click again.";
    }
    if (url) {
      if (tab) tab.go(url);
      else if (!this.env.openUrl(url)) fail = "The browser blocked the new tab. Allow pop-ups for the dashboard, then click again.";
    } else tab?.close();
    this.busy.delete(k);
    this.err = fail;
    this.emit();
  }
}

let inst: Studios | null = null;
export function studios(): Studios {
  if (!inst) inst = new Studios({
    fetch: (u, i) => fetch(u, i),
    openTab: () => {
      const w = window.open("", "_blank");
      if (!w) return null;
      try { w.opener = null; } catch { /* */ }
      return { go: (u) => { w.location.href = u; }, close: () => { try { w.close(); } catch { /* */ } } };
    },
    openUrl: (u) => window.open(u, "_blank", "noopener") !== null,
  });
  return inst;
}
