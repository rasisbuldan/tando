import { describe, expect, it } from "vitest";
import { sidebarGroups } from "./sidebar";
import type { HostView } from "./types";

const app = (name: string, o: Record<string, unknown> = {}) => ({ app: name, state: "active", state_reason: "running", database: null, alerts_firing: 0, ...o });
const host = (name: string, apps: unknown[], o: Record<string, unknown> = {}) =>
  ({ host: name, reachable: true, data: { apps, alerts: [] }, ...o }) as unknown as HostView;

describe("sidebar groups", () => {
  it("empty or loading: nothing, single server", () => {
    expect(sidebarGroups(null)).toMatchObject({ servers: [], apps: [], dbs: [], multi: false });
  });
  it("one row per server, per app across servers (by name), per database app", () => {
    const g = sidebarGroups([
      host("b-vps", [app("shop", { database: "pg", alerts_firing: 2 }), app("blog", { state_reason: "stopped" })]),
      host("a-vps", [app("shop"), app("api", { database: "pg" })]),
    ]);
    expect(g.servers.map((s) => s.host)).toEqual(["a-vps", "b-vps"]);
    expect(g.apps.map((a) => `${a.app}@${a.host}`)).toEqual(["api@a-vps", "blog@b-vps", "shop@a-vps", "shop@b-vps"]);
    expect(g.dbs).toEqual([{ host: "a-vps", app: "api" }, { host: "b-vps", app: "shop" }]);
    expect(g.multi).toBe(true);
    expect(g.apps.find((a) => a.app === "blog")).toMatchObject({ idle: true, kind: "neutral", word: "stopped" });
    expect(g.apps.find((a) => a.app === "shop" && a.host === "b-vps")!.n).toBe(2);
  });
  it("a server that does not answer: stale dots, no database rows, alert totals add up", () => {
    const g = sidebarGroups([
      host("up", [app("x")], { data: { apps: [app("x")], alerts: [{ app: "x", state: "firing" }, { app: "x", state: "pending" }] } }),
      host("down", [app("y", { database: "pg" })], { reachable: false }),
    ]);
    expect(g.servers.map((s) => s.kind)).toEqual(["stale", "fail"]);
    expect(g.apps.find((a) => a.app === "y")).toMatchObject({ kind: "stale", reachable: false });
    expect(g.dbs).toEqual([]);
    expect(g).toMatchObject({ firing: 1, pending: 1 });
  });
});
