import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent } from "react";
import { Link, useLocation, useNavigate } from "react-router";
import { Bell, LayoutDashboard, PanelLeft, Rocket, Monitor, Moon, Sun } from "lucide-react";
import { Dot } from "./ui/badge";
import { Tip } from "./ui/tooltip";
import { Menu, MenuContent, MenuItem, MenuTrigger } from "./ui/dropdown-menu";
import { cn } from "@/lib/cn";
import { sidebarGroups } from "@/lib/sidebar";
import type { HostView } from "@/lib/types";
import { applyTheme, getTheme, lsGet, lsSet, type Theme } from "@/lib/theme";
import { prefetchRoute } from "@/routes";
import { DbRow } from "./studio";

import { forwardRef, type ComponentProps } from "react";
// a link whose class depends on the route; a plain string className so Radix Slot (tooltips) can merge it
const NavLink = forwardRef<HTMLAnchorElement, ComponentProps<typeof Link> & { active: boolean }>(
  ({ active, ...p }, ref) => <Link ref={ref} aria-current={active ? "page" : undefined} {...p} />);
NavLink.displayName = "NavLink";

export const MOBILE_Q = "(max-width: 640px)";

function useMedia(q: string): boolean {
  const [m, setM] = useState(() => matchMedia(q).matches);
  useEffect(() => { const l = matchMedia(q); const f = () => setM(l.matches); l.addEventListener("change", f); return () => l.removeEventListener("change", f); }, [q]);
  return m;
}

export interface SidebarApi { collapsed: boolean; toggle: () => void; mobile: boolean; open: boolean; setOpen: (b: boolean) => void }
export function useSidebar(): SidebarApi {
  const mobile = useMedia(MOBILE_Q);
  const [pref, setPref] = useState(() => lsGet("tando-sidebar") === "collapsed");
  const [open, setOpen] = useState(false);
  const toggle = useCallback(() => {
    if (mobile) setOpen((o) => !o);
    else setPref((p) => { lsSet("tando-sidebar", p ? "expanded" : "collapsed"); return !p; });
  }, [mobile]);
  return { collapsed: mobile ? !open : pref, toggle, mobile, open, setOpen };
}

const ROW = "hov inset-focus group relative flex h-8 w-full items-center gap-2 rounded-md px-2 text-[13px] leading-5 text-foreground hover:bg-muted";
const SEL = "bg-muted font-semibold before:absolute before:inset-y-0 before:left-0 before:w-0.5 before:bg-foreground";

function Count({ n, firing, collapsed }: { n: number; firing: boolean; collapsed: boolean }) {
  if (!n) return null;
  if (collapsed) return <span aria-hidden="true" className={cn("absolute top-1 right-2 size-1.5 rounded-full", firing ? "bg-fail" : "bg-warn")} />;
  return <span className={cn("ml-auto text-xs leading-4 font-medium", firing ? "text-fail" : "text-warn")}>{n}</span>;
}

function Body({ hosts, sb, version, collapsed }: { hosts: HostView[] | null; sb: SidebarApi; version: string; collapsed: boolean }) {
  const loc = useLocation();
  const nav = useNavigate();
  const on = (to: string, end: boolean) => (end ? loc.pathname === to : loc.pathname === to || loc.pathname.startsWith(to + "/"));
  const treeRef = useRef<HTMLDivElement>(null);
  const [theme, setTheme] = useState<Theme>(getTheme);
  const g = useMemo(() => sidebarGroups(hosts), [hosts]);

  // one role=tree, flat: Up/Down move, Home/End jump, Enter opens
  const onKey = (e: KeyboardEvent) => {
    const items = Array.from(treeRef.current?.querySelectorAll<HTMLElement>("[role=treeitem]") ?? []);
    const i = items.indexOf(document.activeElement as HTMLElement);
    if (i < 0) return;
    const cur = items[i];
    const go = (el?: HTMLElement) => { if (el) { e.preventDefault(); el.focus(); } };
    switch (e.key) {
      case "ArrowDown": go(items[i + 1]); break;
      case "ArrowUp": go(items[i - 1]); break;
      case "Home": go(items[0]); break;
      case "End": go(items[items.length - 1]); break;
      case "Enter": e.preventDefault(); if (cur.dataset.level === "db") { cur.click(); break; } nav(cur.getAttribute("href") ?? "/"); if (sb.mobile) sb.setOpen(false); break;
    }
  };

  useEffect(() => { if (sb.mobile) sb.setOpen(false); }, [loc.pathname]); // eslint-disable-line react-hooks/exhaustive-deps

  const page = (to: string, label: string, Icon: typeof Bell, count?: ReactNodeOrNull) => (
    <Tip text={collapsed ? label : ""} side="right">
      <NavLink to={to} active={on(to, to === "/")} role="treeitem" data-level="page" onMouseEnter={() => prefetchRoute(to)} onFocus={() => prefetchRoute(to)}
        aria-label={label + (count ? `, ${count.n} ${count.firing ? "firing" : "pending"}` : "")}
        className={cn(ROW, on(to, to === "/") && SEL)} tabIndex={-1}>
        <Icon size={16} strokeWidth={1.75} aria-hidden="true" className="shrink-0" />
        {!collapsed && <span className="truncate">{label}</span>}
        {count && <Count n={count.n} firing={count.firing} collapsed={collapsed} />}
      </NavLink>
    </Tip>
  );

  const alertCount = g.firing ? { n: g.firing, firing: true } : g.pending ? { n: g.pending, firing: false } : undefined;

  const head = (t: string) => (
    <div className={cn("mt-4 mb-1 px-2 text-[11px] leading-4 font-semibold tracking-[0.04em] text-muted-foreground uppercase", collapsed && "px-0 text-center")}>{collapsed ? "·" : t}</div>
  );

  const body = (
    <nav aria-label="Main" className={cn("flex h-full flex-col border-r border-border bg-card", collapsed ? "w-14" : "w-60")}>
      <div className={cn("flex h-14 shrink-0 items-center gap-2 px-3", collapsed && "justify-center px-0")}>
        {!collapsed && <svg aria-hidden="true" width="20" height="20" viewBox="0 0 16 16" className="shrink-0 text-primary"><rect x="1" y="1" width="14" height="14" rx="3" fill="currentColor" /><path d="M5 5h6M8 5v7" stroke="var(--primary-foreground)" strokeWidth="2" strokeLinecap="round" /></svg>}
        {!collapsed && <span className="text-[15px] leading-[22px] font-semibold">tando</span>}
        <Tip text={collapsed ? "Expand sidebar ([)" : "Collapse sidebar ([)"}>
          <button type="button" aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"} onClick={sb.toggle} className={cn("hov grid size-8 place-items-center rounded-md hover:bg-muted", !collapsed && "ml-auto")}><PanelLeft size={16} strokeWidth={1.75} aria-hidden="true" /></button>
        </Tip>
      </div>
      <div ref={treeRef} role="tree" aria-label="Pages, servers, apps and databases" onKeyDown={onKey} className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-2">
        {page("/", "Overview", LayoutDashboard)}
        {page("/deploys", "Deploys", Rocket)}
        {page("/alerts", "Alerts", Bell, alertCount)}
        {head("Server")}
        {hosts === null && !collapsed && <div aria-busy="true" className="h-16" />}
        {g.servers.map((r) => {
          const n = r.firing || r.pending, to = `/s/${encodeURIComponent(r.host)}`;
          return (
            <Tip key={r.host} text={collapsed ? r.host : ""} side="right">
              <NavLink to={to} active={on(to, true)} role="treeitem" data-level="server" tabIndex={-1}
                aria-label={`${r.host}${r.reachable ? "" : ", not answering"}${n ? `, ${n} alert${n > 1 ? "s" : ""}` : ""}`} onMouseEnter={() => prefetchRoute("/s/")} onFocus={() => prefetchRoute("/s/")}
                className={cn(ROW, on(to, true) && SEL, !r.reachable && "text-muted-foreground")}>
                <Dot kind={r.kind} className="mx-1" />
                {!collapsed && <span className="truncate">{r.host}</span>}
                {!collapsed && !r.reachable && <span className="ml-auto text-xs text-muted-foreground">not answering</span>}
                {r.reachable && <Count n={n} firing={r.firing > 0} collapsed={collapsed} />}
              </NavLink>
            </Tip>
          );
        })}
        {hosts !== null && g.servers.length === 0 && !collapsed && <p className="m-0 px-2 text-[13px] text-muted-foreground">No servers. Add one with <code>tando host add</code>.</p>}
        {g.apps.length > 0 && head("Apps")}
        {g.apps.map((a) => {
          const to = `/s/${encodeURIComponent(a.host)}/${a.app}`;
          return (
            <Tip key={a.host + "/" + a.app} text={collapsed ? `${a.app}${g.multi ? ` (${a.host})` : ""}` : ""} side="right">
              <NavLink to={to} active={on(to, false)} role="treeitem" data-level="app" tabIndex={-1}
                aria-label={`${a.app}${g.multi ? ` on ${a.host}` : ""}, ${a.reachable ? a.word : "last state " + a.word + ", stale"}${a.n ? `, ${a.n} alert${a.n > 1 ? "s" : ""}` : ""}`}
                onMouseEnter={() => prefetchRoute("/s/x/y")} onFocus={() => prefetchRoute("/s/x/y")}
                className={cn(ROW, on(to, false) && SEL, (!a.reachable || a.idle) && "text-muted-foreground")}>
                <Dot kind={a.kind} className="mx-1" />
                {!collapsed && <span className="truncate">{a.app}{g.multi && <span className="ml-1.5 text-xs text-muted-foreground">{a.host}</span>}</span>}
                {!collapsed && a.idle && a.n === 0 && <span className="ml-auto text-xs">{a.word === "never deployed" ? "new" : a.word}</span>}
                {a.n > 0 && <Count n={a.n} firing collapsed={collapsed} />}
              </NavLink>
            </Tip>
          );
        })}
        {g.dbs.length > 0 && head("Database")}
        {g.dbs.map((d) => <DbRow key={d.host + "/" + d.app} host={d.host} app={d.app} showHost={g.multi} collapsed={collapsed} />)}
      </div>
      <div className={cn("flex h-12 shrink-0 items-center gap-2 border-t border-border px-3", collapsed && "justify-center px-0")}>
        <Menu>
          <Tip text="Theme"><MenuTrigger asChild><button type="button" aria-label="Theme" className="hov grid size-8 place-items-center rounded-md hover:bg-muted">
            {theme === "dark" ? <Moon size={16} strokeWidth={1.75} aria-hidden="true" /> : theme === "light" ? <Sun size={16} strokeWidth={1.75} aria-hidden="true" /> : <Monitor size={16} strokeWidth={1.75} aria-hidden="true" />}
          </button></MenuTrigger></Tip>
          <MenuContent side="top" align="start">
            {(["system", "light", "dark"] as Theme[]).map((t) => (
              <MenuItem key={t} onSelect={() => { setTheme(t); applyTheme(t); }} className={cn(theme === t && "font-semibold")}>{t[0].toUpperCase() + t.slice(1)}</MenuItem>
            ))}
          </MenuContent>
        </Menu>
        {!collapsed && <span className="text-xs text-muted-foreground">{version}</span>}
        {collapsed && sb.mobile && null}
      </div>
    </nav>
  );

  return body;
}
type ReactNodeOrNull = { n: number; firing: boolean } | undefined;

export function Sidebar({ hosts, sb, version }: { hosts: HostView[] | null; sb: SidebarApi; version: string }) {
  if (sb.mobile) {
    // at <= 640 px: a 56 px rail; the button opens the 280 px sheet over the content (no reflow)
    return (
      <>
        <div className="h-full w-14 shrink-0"><Body hosts={hosts} sb={sb} version={version} collapsed /></div>
        {sb.open && (
          <>
            <div className="fixed inset-0 z-30" aria-hidden="true" onClick={() => sb.setOpen(false)} />
            <div className="pop fixed inset-y-0 left-0 z-40 w-70 shadow-pop"><Body hosts={hosts} sb={sb} version={version} collapsed={false} /></div>
          </>
        )}
      </>
    );
  }
  return <div className="h-full shrink-0"><Body hosts={hosts} sb={sb} version={version} collapsed={sb.collapsed} /></div>;
}
