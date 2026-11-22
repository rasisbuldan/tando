// The database studio: the sidebar's "Database" row under an app with a database, the app
// header's "Open database", the server page's "Database studio", and one line for a failure.
// A click opens the studio in a new tab at once (lib/studio.ts); there is no dialog.
import { useSyncExternalStore } from "react";
import { Database, X } from "lucide-react";
import { Button } from "./ui/button";
import { Tip } from "./ui/tooltip";
import { cn } from "@/lib/cn";
import { studios } from "@/lib/studio";

function useOpening(host: string, app: string): boolean {
  const s = studios();
  const snap = useSyncExternalStore(s.subscribe, s.get);
  return snap.opening.includes(`${host}/${app}`);
}

const ROW = "hov inset-focus group relative flex h-8 w-full items-center gap-2 rounded-md text-[13px] leading-5 text-foreground hover:bg-muted";

/** the sidebar's Database group: one row per app with a database; a click opens its studio */
export function DbRow({ host, app, showHost, collapsed }: { host: string; app: string; showHost: boolean; collapsed: boolean }) {
  const opening = useOpening(host, app);
  return (
    <Tip text={collapsed ? `Database of ${app}` : ""} side="right">
      <button type="button" role="treeitem" data-level="db" data-host={host} tabIndex={-1}
        aria-label={`Database of ${app}${showHost ? ` on ${host}` : ""}, opens the studio${opening ? ", opening" : ""}`}
        onClick={() => void studios().open(host, app)}
        className={cn(ROW, "px-2", collapsed && "justify-center")}>
        <Database size={14} strokeWidth={1.75} aria-hidden="true" className="mx-0.5 shrink-0 text-muted-foreground" />
        {!collapsed && <span className="truncate">{app}{showHost && <span className="ml-1.5 text-xs text-muted-foreground">{host}</span>}</span>}
        {!collapsed && <span className="ml-auto text-xs text-muted-foreground">{opening ? "opening…" : "studio"}</span>}
      </button>
    </Tip>
  );
}

/** the app header's button (same action as the sidebar row) */
export function StudioButton({ host, app }: { host: string; app: string }) {
  const opening = useOpening(host, app);
  return (
    <Button onClick={() => void studios().open(host, app)} disabled={opening}>
      <Database size={14} strokeWidth={1.75} aria-hidden="true" />{opening ? "Opening…" : "Open database"}
    </Button>
  );
}

/** the server page's button: the studio opens on `app`; its own list switches between the server's apps */
export function ServerStudioButton({ host, app }: { host: string; app: string }) {
  const opening = useOpening(host, app);
  return (
    <Button onClick={() => void studios().open(host, app)} disabled={opening}>
      <Database size={14} strokeWidth={1.75} aria-hidden="true" />{opening ? "Opening…" : "Database studio"}
    </Button>
  );
}

/** a failed open, one line, once in the shell */
export function StudioNotice() {
  const s = studios();
  const snap = useSyncExternalStore(s.subscribe, s.get);
  if (!snap.error) return null;
  return (
    <div role="alert" className="fixed right-4 bottom-4 z-50 flex max-w-[calc(100vw-32px)] items-start gap-3 rounded-lg border border-border bg-popover p-3 text-[13px] shadow-pop sm:max-w-[420px]">
      <p className="m-0 min-w-0 flex-1 break-words text-fail">{snap.error}</p>
      <button type="button" aria-label="Dismiss" onClick={() => s.dismiss()} className="hov inset-focus -m-1 grid size-6 shrink-0 place-items-center rounded-md hover:bg-muted"><X size={14} aria-hidden="true" /></button>
    </div>
  );
}
