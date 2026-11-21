// Writes on the app page: header actions, the confirmation dialog, the progress panel
// (DESIGN sections 6, 7 and 9). The state lives in lib/actions.ts, so the panel survives
// navigation and a reload reattaches to it.
import { useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { Link } from "react-router";
import { Badge } from "./ui/badge";
import { Button } from "./ui/button";
import { Input } from "./ui/select";
import { Tip } from "./ui/tooltip";
import { refreshAll, useNowMs } from "@/lib/resources";
import { apiGet } from "@/lib/api";
import { cn } from "@/lib/cn";
import {
  actions, actionNoun, commandFor, conflictLine, deployBlocked, dialogCopy, endView, envKeyError, envValueError, gmt, runningLine,
  type ActionName, type Slot,
} from "@/lib/actions";
import type { Release } from "@/lib/types";
import { rollbackTarget } from "@/lib/shape";

export function useSlot(host: string, app: string): Slot {
  const a = actions();
  return useSyncExternalStore(a.subscribe, () => a.get(host, app));
}

// user@machine of this tando-dash (the deploy button's check); asked once per page load
let client: string | null = null, asked = false;
const clientSubs = new Set<() => void>();
export function useClient(): string | null {
  return useSyncExternalStore((f) => {
    clientSubs.add(f);
    if (!asked) {
      asked = true;
      apiGet<{ client?: string }>("/api/ping").then((r) => { client = r.client ?? null; clientSubs.forEach((g) => g()); }).catch(() => { asked = false; });
    }
    return () => { clientSubs.delete(f); };
  }, () => client);
}

const isMac = () => typeof navigator !== "undefined" && /Mac/i.test(navigator.platform || navigator.userAgent);

export interface AppCtx { host: string; app: string; state: string | null; reachable: boolean; origin: string | null | undefined; releases: Release[]; live: string | null }

/** why an action is off, or null */
export function blocked(ctx: AppCtx, slot: Slot, action: ActionName, client: string | null): string | null {
  const o = slot.op;
  if (o && o.status === "running") return `A ${actionNoun(o.action)} is running.`;
  if (!ctx.reachable) return `${ctx.host} not answering. Check ssh access, then retry.`;
  if (action === "deploy") return deployBlocked(ctx.app, ctx.host, ctx.origin, client);
  if (action === "rollback" && !rollbackTarget(ctx.releases)) return "No rollback target: no earlier healthy release.";
  if ((action === "restart" || action === "stop") && (ctx.state === "not_deployed" || ctx.state === "stopped")) return ctx.state === "stopped" ? `${ctx.app} is stopped.` : `${ctx.app} was never deployed.`;
  if (action === "start" && ctx.state === "not_deployed") return `${ctx.app} was never deployed.`;
  return null;
}

/** a button that may be off: the reason in a tooltip (a wrapper takes the hover, a disabled button cannot) */
function Act({ why, children, ...p }: { why: string | null; children: ReactNode } & React.ComponentProps<typeof Button>) {
  if (!why) return <Button {...p}>{children}</Button>;
  return <Tip text={why}><span tabIndex={0} aria-label={`${String(children)}: ${why}`} className="inline-flex rounded-md"><Button {...p} disabled>{children}</Button></span></Tip>;
}

/** Deploy, Roll back, Restart, Stop or Start, in that order; the dialog when one is open */
export function AppActions({ ctx }: { ctx: AppCtx }) {
  const slot = useSlot(ctx.host, ctx.app);
  const cl = useClient();
  const a = actions();
  const stopped = ctx.state === "stopped";
  return (
    <>
      <div className="flex items-center gap-2 max-lg:hidden">
        <Act why={blocked(ctx, slot, "deploy", cl)} variant="primary" onClick={() => a.open(ctx.host, ctx.app, "deploy")}>Deploy</Act>
        <Act why={blocked(ctx, slot, "rollback", cl)} onClick={() => a.open(ctx.host, ctx.app, "rollback")}>Roll back</Act>
        <Act why={blocked(ctx, slot, "restart", cl)} onClick={() => a.open(ctx.host, ctx.app, "restart")}>Restart</Act>
        {stopped
          ? <Act why={blocked(ctx, slot, "start", cl)} onClick={() => a.open(ctx.host, ctx.app, "start")}>Start</Act>
          : <Act why={blocked(ctx, slot, "stop", cl)} onClick={() => a.open(ctx.host, ctx.app, "stop")}>Stop</Act>}
      </div>
      <div className="lg:hidden">
        <Act why={blocked(ctx, slot, "deploy", cl)} variant="primary" onClick={() => a.open(ctx.host, ctx.app, "deploy")}>Deploy</Act>
      </div>
      {slot.dialog && <ActionDialog ctx={ctx} slot={slot} />}
    </>
  );
}

/** the confirmation (native <dialog>: focus trapped, Esc closes, focus returns to the trigger) */
export function ActionDialog({ ctx, slot }: { ctx: AppCtx; slot: Slot }) {
  const d = slot.dialog!;
  const a = actions();
  const ref = useRef<HTMLDialogElement>(null);
  const valRef = useRef<HTMLInputElement>(null);
  const [key, setKey] = useState(d.params.key ?? "");
  const [touched, setTouched] = useState(false);
  const [valErr, setValErr] = useState<string | null>(null);
  const nowMs = useNowMs(1000);
  useEffect(() => {
    const el = ref.current;
    if (el && !el.open) { try { el.showModal(); } catch { el.setAttribute("open", ""); } }
    return () => { try { el?.close(); } catch { /* */ } };
  }, []);
  // an answer came back (not a lost request): the value is gone from the field
  const answered = !d.sending && !d.sendFailed;
  useEffect(() => { if (answered && valRef.current) valRef.current.value = ""; }, [answered, d.error, d.conflict]);

  const target = d.params.release ?? rollbackTarget(ctx.releases);
  const copy = dialogCopy(d.action, ctx.host, ctx.app, { ...d.params, origin: ctx.origin, target, live: ctx.live, mac: isMac() });
  const env = d.action === "env-set";
  const kErr = env ? envKeyError(key) : null;
  const cmd = commandFor(d.action, ctx.host, ctx.app, { ...d.params, release: d.action === "rollback" ? d.params.release : undefined, key: env ? key : undefined });
  const cancel = () => a.cancel(ctx.host, ctx.app);
  const submit = () => {
    if (env) {
      setTouched(true);
      const v = valRef.current?.value ?? "";
      const ve = envValueError(v);
      setValErr(ve);
      if (kErr || ve) return;
      void a.send(ctx.host, ctx.app, v, { key });
      return;
    }
    void a.send(ctx.host, ctx.app);
  };
  const label = d.sendFailed && !d.sending ? "Retry" : d.preparing && !d.sending ? "Preparing…" : copy.button;
  const off = d.sending || (d.preparing && !d.sendFailed) || (!d.token && !d.sendFailed);

  return (
    <dialog ref={ref} aria-labelledby="act-title" onCancel={(e) => { e.preventDefault(); cancel(); }}
      className="pop m-auto w-[440px] max-w-[calc(100vw-32px)] rounded-lg border border-border bg-popover p-0 text-foreground shadow-pop backdrop:bg-foreground/40">
      <form method="dialog" className="flex flex-col gap-3 p-4" onSubmit={(e) => { e.preventDefault(); submit(); }}>
        <h2 id="act-title" className="m-0 text-[15px] leading-[22px] font-semibold">{copy.title}</h2>
        {d.conflict ? (
          <>
            <p className="m-0 text-sm">{conflictLine(ctx.app, d.conflict, nowMs)}</p>
            <div className="flex justify-between gap-2 pt-1">
              <Button type="button" size="md" onClick={cancel} autoFocus>Close</Button>
              <Button type="button" size="md" variant="primary" onClick={() => a.view(ctx.host, ctx.app, d.conflict!)}>Show progress</Button>
            </div>
          </>
        ) : (
          <>
            <p className="m-0 text-sm break-words">{copy.body}</p>
            {env && (
              <div className="flex flex-col gap-2">
                <label className="flex flex-col gap-1 text-[13px] font-medium">Key
                  <Input value={key} onChange={(e) => setKey(e.target.value)} onBlur={() => setTouched(true)} autoFocus autoComplete="off" spellCheck={false}
                    aria-invalid={touched && !!kErr} className="mono" name="env-key" />
                </label>
                {touched && kErr && <p className="m-0 text-xs text-fail">{kErr}</p>}
                <label className="flex flex-col gap-1 text-[13px] font-medium">Value
                  <Input ref={valRef} type="password" autoComplete="off" spellCheck={false} name="env-value" data-lpignore="true" defaultValue="" />
                </label>
                {valErr && <p className="m-0 text-xs text-fail">{valErr}</p>}
              </div>
            )}
            <code className="block truncate rounded-sm bg-muted px-2 py-1" title={cmd}>{cmd}</code>
            {(d.tokenError || d.error) && <p role="alert" className="m-0 text-[13px] text-fail">{d.error ?? d.tokenError}</p>}
            <div className="flex justify-between gap-2 pt-1">
              <Button type="button" size="md" onClick={cancel} disabled={d.sending} autoFocus={copy.destructive && !env}>Cancel</Button>
              <Button type="submit" size="md" variant={copy.destructive ? "destructive" : "primary"} disabled={off} autoFocus={!copy.destructive && !env}>{label}</Button>
            </div>
          </>
        )}
      </form>
    </dialog>
  );
}

const KIND = { ok: "ok", fail: "fail", stale: "stale" } as const;

/** inline under the header while a write runs and after it ended (Close) */
export function ProgressPanel({ host, app }: { host: string; app: string }) {
  const slot = useSlot(host, app);
  const o = slot.op;
  const nowMs = useNowMs(1000);
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => { const b = box.current; if (b) b.scrollTop = b.scrollHeight; }, [o?.lines.length]);
  // the end: the header and tables read the server again (its truth, not ours)
  const ended = !!o && o.status !== "running";
  useEffect(() => { if (ended) refreshAll(); }, [ended]);
  if (!o) return null;
  const running = o.status === "running";
  const ev = !running && o.record ? endView(o.record, o.varName) : null;
  return (
    <section aria-label="Progress" className="mb-4 rounded-lg border border-border bg-card">
      <div className="flex min-h-10 items-center gap-3 border-b border-border px-4 py-2">
        {running ? <Badge kind="info">running</Badge> : ev ? <Badge kind={KIND[ev.kind]}>{ev.badge}</Badge> : <Badge kind="stale">unknown</Badge>}
        <span className="min-w-0 flex-1 truncate text-[13px]">{runningLine(o, running ? nowMs : Date.parse(o.record?.ended_at ?? "") || nowMs, !running)}</span>
        {!running && <Button onClick={() => actions().close(host, app)}>Close</Button>}
      </div>
      <div className="px-4 py-2">
        {o.reattached && <p className="m-0 text-xs text-muted-foreground">Reattached to the {actionNoun(o.action)} started {gmt(o.startedAt)}.</p>}
        {o.replay && <p className="m-0 text-xs text-muted-foreground">Already sent. Showing the first request.</p>}
        {o.dropped > 0 && <p className="m-0 text-xs text-muted-foreground">Showing the last {o.lines.length} lines.</p>}
        {o.streamError && <p className="m-0 text-xs text-muted-foreground">{o.streamError}</p>}
        <div ref={box} className="my-2 h-[216px] overflow-auto rounded-md bg-muted px-2 py-1" aria-label="Output" tabIndex={0}>
          {o.lines.length === 0 ? <p className="m-0 text-xs text-muted-foreground">{running ? "Waiting for output…" : "No output."}</p>
            : o.lines.map((l, i) => <div key={i} className="mono h-[18px] truncate whitespace-pre" title={l}>{l}</div>)}
        </div>
        <div role="status" className="min-h-5 text-[13px]">
          {ev && (
            <p className="m-0">
              <span className={cn(ev.kind === "fail" && "text-fail")}>{ev.line}</span>
              {ev.next && <span className="text-muted-foreground"> {ev.next}</span>}
              {ev.showLog && <> <Link className="underline underline-offset-2" to={`/s/${encodeURIComponent(host)}/${app}/logs`}>Show log</Link></>}
            </p>
          )}
        </div>
      </div>
    </section>
  );
}

/** "Roll back to this" in the Releases table */
export function useRollbackTo(ctx: AppCtx | null): { why: (id: string) => string | null; go: (id: string) => void } | null {
  const slot = useSlot(ctx?.host ?? "", ctx?.app ?? "");
  const cl = useClient();
  if (!ctx) return null;
  return {
    why: () => { const w = blocked(ctx, slot, "rollback", cl); return w && !w.startsWith("No rollback target") ? w : null; },
    go: (id) => actions().open(ctx.host, ctx.app, "rollback", { release: id }),
  };
}
export { Act };
