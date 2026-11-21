// The database studio: the sidebar's "Database" row under an app with a database, the app
// header's "Open database", and the one confirmation dialog (lib/studio.ts holds the state).
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Database } from "lucide-react";
import { Button } from "./ui/button";
import { cn } from "@/lib/cn";
import { entryState, studioCopy, studios, type EntryState } from "@/lib/studio";

export function useStudio(host: string, app: string): EntryState {
  const s = studios();
  const snap = useSyncExternalStore(s.subscribe, s.get);
  return entryState(host, app, snap.list, snap.dialog);
}

const ROW = "hov inset-focus group relative flex h-8 w-full items-center gap-2 rounded-md text-[13px] leading-5 text-foreground hover:bg-muted";

/** the sidebar row under an app: "Database", and "open · Stop" while the dashboard's studio of it runs */
export function StudioRow({ host, app }: { host: string; app: string }) {
  const st = useStudio(host, app);
  const [err, setErr] = useState<string | null>(null);
  const open = st.kind === "open";
  return (
    <div className="flex items-center">
      <button type="button" role="treeitem" data-level="studio" data-host={host} tabIndex={-1}
        aria-label={`Database of ${app}${open ? ", open" : st.kind === "opening" ? ", opening" : ""}`}
        onClick={() => { setErr(null); void studios().ask(host, app); }}
        className={cn(ROW, "flex-1 pl-9 pr-2 text-muted-foreground")}>
        <Database size={14} strokeWidth={1.75} aria-hidden="true" className="shrink-0" />
        <span className="truncate">Database</span>
        {open && <span className="ml-auto text-xs text-ok">open</span>}
        {st.kind === "opening" && <span className="ml-auto text-xs">opening…</span>}
      </button>
      {open && (
        <button type="button" tabIndex={-1} title={err ?? undefined} aria-label={`Stop the database studio of ${app}`}
          onClick={async () => setErr(await studios().stop(host, app))}
          className="hov inset-focus h-8 shrink-0 rounded-md px-2 text-xs hover:bg-muted">Stop</button>
      )}
    </div>
  );
}

/** the app header's button (same action as the sidebar row) */
export function StudioButton({ host, app }: { host: string; app: string }) {
  const st = useStudio(host, app);
  return (
    <Button onClick={() => void studios().ask(host, app)} disabled={st.kind === "opening"}>
      <Database size={14} strokeWidth={1.75} aria-hidden="true" />{st.kind === "open" ? "Database open" : "Open database"}
    </Button>
  );
}

/** the confirmation (native <dialog>), once in the shell */
export function StudioDialogHost() {
  const s = studios();
  const snap = useSyncExternalStore(s.subscribe, s.get);
  const d = snap.dialog;
  if (!d) return null;
  return <StudioDialogView key={`${d.host}/${d.app}`} />;
}

function StudioDialogView() {
  const s = studios();
  const snap = useSyncExternalStore(s.subscribe, s.get);
  const d = snap.dialog!;
  const st = entryState(d.host, d.app, snap.list, d);
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (el && !el.open) { try { el.showModal(); } catch { el.setAttribute("open", ""); } }
    return () => { try { el?.close(); } catch { /* */ } };
  }, []);
  const copy = studioCopy(d.host, d.app);
  const already = st.kind === "open" && !d.url;
  const taken = st.kind === "taken" && !d.url;
  return (
    <dialog ref={ref} aria-labelledby="studio-title" onCancel={(e) => { e.preventDefault(); s.close(); }}
      className="pop m-auto w-[440px] max-w-[calc(100vw-32px)] rounded-lg border border-border bg-popover p-0 text-foreground shadow-pop backdrop:bg-foreground/40">
      <form method="dialog" className="flex flex-col gap-3 p-4" onSubmit={(e) => { e.preventDefault(); void s.confirm(); }}>
        <h2 id="studio-title" className="m-0 text-[15px] leading-[22px] font-semibold">{d.url ? `Database of ${d.app} open` : copy.title}</h2>
        {d.url ? (
          <p className="m-0 text-sm">The studio opened in a new window. Nothing opened? <a href={d.url} target="_blank" rel="noopener noreferrer" className="underline underline-offset-2">Open it here</a> (the link works once).</p>
        ) : already ? (
          <p className="m-0 text-sm">The studio of {d.app} is open in another window. Stop it to start a new one.</p>
        ) : taken ? (
          <p className="m-0 text-sm">The dashboard has the studio of {st.kind === "taken" ? st.by : ""} open on {d.host} (one per server). Stop it first.</p>
        ) : (
          <>
            <p className="m-0 text-sm break-words">{copy.body}</p>
            <code className="block truncate rounded-sm bg-muted px-2 py-1" title={copy.command}>{copy.command}</code>
          </>
        )}
        {d.error && <p role="alert" className="m-0 text-[13px] text-fail">{d.error}</p>}
        <div className="flex justify-between gap-2 pt-1">
          <Button type="button" size="md" onClick={() => s.close()} disabled={d.sending} autoFocus={!!d.url || already || taken}>{d.url ? "Close" : "Cancel"}</Button>
          {already && <Button type="button" size="md" variant="destructive" onClick={() => void s.stop(d.host, d.app)}>Stop</Button>}
          {!d.url && !already && !taken && (
            <Button type="submit" size="md" variant="primary" autoFocus disabled={d.sending || !d.token}>{d.sending ? "Opening…" : d.preparing ? "Preparing…" : "Open"}</Button>
          )}
        </div>
      </form>
    </dialog>
  );
}
