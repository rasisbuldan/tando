import { cn } from "@/lib/cn";
import type { Kind } from "@/lib/shape";

const KIND: Record<Kind, string> = {
  ok: "text-ok bg-ok-bg border-ok-border", warn: "text-warn bg-warn-bg border-warn-border", fail: "text-fail bg-fail-bg border-fail-border",
  stale: "text-stale bg-stale-bg border-stale-border", info: "text-info bg-info-bg border-info-border", neutral: "text-neutral bg-neutral-bg border-neutral-border",
};
const DOT: Record<Kind, string> = {
  ok: "bg-ok", warn: "bg-warn", fail: "bg-fail", info: "bg-info", neutral: "bg-neutral", stale: "border border-input bg-transparent",
};
/** 8 px dot; always next to a word or in a row whose name says it */
export function Dot({ kind, className }: { kind: Kind; className?: string }) {
  return <span aria-hidden="true" className={cn("inline-block size-2 shrink-0 rounded-full", DOT[kind], className)} />;
}
/** 22 px pill: state text on state background; always a word */
export function Badge({ kind, children, dot = true, className }: { kind: Kind; children: React.ReactNode; dot?: boolean; className?: string }) {
  return (
    <span className={cn("inline-flex h-[22px] items-center gap-1.5 rounded-full border px-2 text-xs leading-4 font-medium whitespace-nowrap", KIND[kind], className)}>
      {dot && <span aria-hidden="true" className={cn("inline-block size-1.5 rounded-full", DOT[kind])} />}{children}
    </span>
  );
}
export function Tag({ children }: { children: React.ReactNode }) {
  return <span className="inline-flex h-[22px] items-center rounded-full border border-border bg-muted px-2 text-xs leading-4 font-medium text-neutral">{children}</span>;
}
