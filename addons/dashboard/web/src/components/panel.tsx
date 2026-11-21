import { Component, type ReactNode } from "react";
import { RefreshCw } from "lucide-react";
import { Button } from "./ui/button";
import { Skeleton } from "./ui/skeleton";
import { Badge } from "./ui/badge";
import { cn } from "@/lib/cn";
import { fmtTime } from "@/lib/format";
import { refreshAll, useNowMs, useStale } from "@/lib/resources";
import type { PollState } from "@/lib/poller";
import { useEffect, useState } from "react";

/** one error boundary per panel: a broken view never takes the page down */
export class PanelBoundary extends Component<{ children: ReactNode; minH?: string }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <div role="alert" className={cn("flex items-center gap-3 rounded-lg border border-fail-border bg-fail-bg p-4 text-[13px]", this.props.minH)}>
        <span>This panel failed to draw. Reload the page.</span>
        <Button onClick={() => location.reload()}>Reload</Button>
      </div>
    );
  }
}

/** loading is shown after 150 ms only; before that nothing changes */
export function useAfter(ms: number, on: boolean): boolean {
  const [late, setLate] = useState(false);
  useEffect(() => {
    if (!on) { setLate(false); return; }
    const h = setTimeout(() => setLate(true), ms);
    return () => clearTimeout(h);
  }, [ms, on]);
  return late;
}

/** Section: heading + its own boundary + loading / error / empty body. `h` = reserved body height class. */
export function Section({ title, aside, children, className }: { title: string; aside?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={cn("mb-4", className)} aria-label={title}>
      <div className="mb-2 flex h-[22px] items-center justify-between gap-2">
        <h2 className="m-0 text-[15px] leading-[22px] font-semibold">{title}</h2>
        {aside}
      </div>
      <PanelBoundary>{children}</PanelBoundary>
    </section>
  );
}

export function Loading({ h = "h-24", on = true }: { h?: string; on?: boolean }) {
  const show = useAfter(150, on);
  return <div aria-busy="true" className={cn("rounded-lg", h)}>{show && <Skeleton className="size-full" />}</div>;
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="rounded-lg border border-border bg-card p-4 text-[13px] text-muted-foreground">{children}</div>;
}

export function SectionError({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div role="alert" className="flex items-center justify-between gap-3 rounded-lg border border-fail-border bg-fail-bg p-4 text-[13px]">
      <span>{message}</span>
      {onRetry && <Button onClick={onRetry}><RefreshCw size={16} strokeWidth={1.75} aria-hidden="true" />Retry</Button>}
    </div>
  );
}

/** the 24 px freshness row: always present, holds the age or the stale text, never inserts space */
export function Freshness({ st }: { st: PollState<unknown> }) {
  const now = useNowMs(1000);
  const stale = useStale(st);
  const [live, setLive] = useState("");
  useEffect(() => { setLive(stale ? "Data is stale" : ""); }, [stale]);
  let body: ReactNode = null;
  if (st.lastOkMs != null) {
    if (stale) {
      body = (<><Badge kind="stale">stale</Badge><span>data from {fmtTime(st.fetchedAtS)}, retrying</span></>);
    } else {
      const d = Math.max(0, Math.floor((now - st.lastOkMs) / 1000));
      body = <span title={fmtTime(st.fetchedAtS)}>updated {d < 5 ? "just now" : `${d} s ago`}</span>;
    }
  } else if (st.error) {
    body = <span>{st.error.message}</span>;
  }
  return (
    <div className="flex h-6 items-center gap-2 text-xs leading-4 text-muted-foreground" aria-live="polite">
      {body}<span className="sr-only">{live}</span>
    </div>
  );
}

export function RefreshButton() {
  return <Button onClick={refreshAll}><RefreshCw size={16} strokeWidth={1.75} aria-hidden="true" />Refresh</Button>;
}

export function PageHeader({ title, badge, meta, actions }: { title: ReactNode; badge?: ReactNode; meta?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="sticky top-0 z-10 flex h-14 items-center justify-between gap-3 border-b border-border bg-background">
      <div className="flex min-w-0 items-center gap-3">
        <h1 className="m-0 truncate text-xl leading-7 font-semibold">{title}</h1>
        {badge}
        {meta && <div className="truncate text-[13px] text-muted-foreground max-sm:hidden">{meta}</div>}
      </div>
      <div className="flex shrink-0 items-center gap-2">{actions}</div>
    </div>
  );
}

/** the right layout with nothing in it yet (M3/M5 fill these) */
export function Placeholder({ name }: { name: string }) {
  return (
    <div className="flex h-60 flex-col items-center justify-center gap-1 rounded-lg border border-border bg-card text-center">
      <p className="m-0 text-[15px] leading-[22px] font-semibold">{name}</p>
      <p className="m-0 text-[13px] text-muted-foreground">Coming in a later version.</p>
    </div>
  );
}
