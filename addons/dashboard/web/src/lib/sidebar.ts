// The sidebar's three groups, derived from the hosts: Server (one row per server), Apps (one row
// per app across all servers), Database (one row per app with a database). Pure; tested.
import { appKind, worstKind, type Kind } from "./shape";
import type { HostView } from "./types";

export interface ServerRow { host: string; reachable: boolean; kind: Kind; firing: number; pending: number }
export interface AppNav { host: string; app: string; kind: Kind; word: string; n: number; reachable: boolean; idle: boolean }
export interface DbNav { host: string; app: string }
export interface Groups { servers: ServerRow[]; apps: AppNav[]; dbs: DbNav[]; multi: boolean; firing: number; pending: number }

const IDLE = new Set(["stopped", "static", "not_deployed", "idle"]);

export function sidebarGroups(hosts: HostView[] | null): Groups {
  const hs = [...(hosts ?? [])].sort((a, b) => a.host.localeCompare(b.host));
  const servers: ServerRow[] = [], apps: AppNav[] = [], dbs: DbNav[] = [];
  let firing = 0, pending = 0;
  for (const h of hs) {
    const alerts = h.data?.alerts ?? [];
    const f = alerts.filter((a) => a.state === "firing").length, p = alerts.length - f;
    firing += f; pending += p;
    const kinds: Kind[] = [];
    for (const a of h.data?.apps ?? []) {
      const k = appKind(a);
      const kind: Kind = h.reachable ? k.kind : "stale";
      kinds.push(kind);
      apps.push({ host: h.host, app: a.app, kind, word: k.word, n: a.alerts_firing ?? 0, reachable: h.reachable, idle: IDLE.has(a.state_reason) });
      if (a.database && h.reachable) dbs.push({ host: h.host, app: a.app });
    }
    const kind: Kind = !h.reachable ? "stale" : worstKind(kinds.concat(f ? ["fail"] : p ? ["warn"] : []));
    servers.push({ host: h.host, reachable: h.reachable, kind, firing: f, pending: p });
  }
  const by = (a: { app: string; host: string }, b: { app: string; host: string }) => a.app.localeCompare(b.app) || a.host.localeCompare(b.host);
  apps.sort(by); dbs.sort(by);
  return { servers, apps, dbs, multi: hs.length > 1, firing, pending };
}
