import { Check, Copy } from "lucide-react";
import { useState, type ReactNode } from "react";
import { Tip } from "./ui/tooltip";
import { Button } from "./ui/button";
import { Card } from "./ui/card";
import { cn } from "@/lib/cn";
import { DASH, fmtAgo, fmtDateTime } from "@/lib/format";
import type { Phase } from "@/lib/shape";
import { fmtDurShort, fmtSecs } from "@/lib/format";
import { PHASES } from "@/lib/shape";

export const Missing = () => <span className="text-faint">{DASH}</span>;
export function Mono({ children, className }: { children: ReactNode; className?: string }) { return <span className={cn("mono", className)}>{children}</span>; }

/** relative age; the exact GMT time in a tooltip */
export function Age({ t, nowS }: { t: number | null | undefined; nowS: number }) {
  if (t == null) return <Missing />;
  return <Tip text={fmtDateTime(t)}><span>{fmtAgo(nowS, t)}</span></Tip>;
}

export function Cell({ children, sub }: { children: ReactNode; sub?: ReactNode }) {
  return <>{children}{sub != null && <span className="text-muted-foreground"> · {sub}</span>}</>;
}

/** the CLI equivalent, with a copy button */
export function Command({ cmd }: { cmd: string }) {
  const [done, setDone] = useState(false);
  return (
    <span className="inline-flex items-center gap-2">
      <code className="rounded-sm bg-muted px-2 py-0.5">{cmd}</code>
      <Tip text={done ? "Copied" : "Copy command"}>
        <Button variant="ghost" size="icon" aria-label="Copy command" onClick={() => { void navigator.clipboard?.writeText(cmd); setDone(true); setTimeout(() => setDone(false), 1500); }}>
          {done ? <Check size={16} strokeWidth={1.75} aria-hidden="true" /> : <Copy size={16} strokeWidth={1.75} aria-hidden="true" />}
        </Button>
      </Tip>
    </span>
  );
}

/** 96 px metric card; a link when it navigates */
export function MetricCard({ label, value, unit, sub, right }: { label: string; value: ReactNode; unit?: string; sub?: ReactNode; right?: ReactNode }) {
  return (
    <Card className="flex h-24 items-start justify-between overflow-hidden">
      <div className="min-w-0">
        <div className="text-[13px] leading-5 font-medium text-muted-foreground">{label}</div>
        <div className="truncate text-2xl leading-[30px] font-semibold">{value}{unit && <span className="ml-1 text-[13px] leading-5 font-normal text-muted-foreground">{unit}</span>}</div>
        <div className="truncate text-xs leading-4 text-muted-foreground">{sub}</div>
      </div>
      {right}
    </Card>
  );
}

const PHASE_FILL = ["text-chart-1", "text-chart-2", "text-chart-3", "text-chart-4", "text-chart-5", "text-chart-6"];
const PHASE_KEYS = ["build_s", "upload_s", "release_s", "preflight_s", "switch_s", "verify_s"];
/** horizontal stacked bar (SVG width attributes, no style prop), total to the right in the short form.
 *  Each segment has its own hover: the phase and its seconds. */
export function PhaseBar({ phases, total, label }: { phases: Phase[]; total: number | null; label: string }) {
  const sum = phases.reduce((s, p) => s + p.s, 0);
  const W = 120;
  let x = 0;
  return (
    <span className="inline-flex items-center gap-2 whitespace-nowrap">
      <svg role="img" aria-label={label} width={W} height="16" className="shrink-0">
        {sum > 0 && phases.map((p) => {
          const w = Math.max(2, (p.s / sum) * W);
          const el = (
            <rect key={p.key} x={x} y="0" width={Math.max(0, w - 1)} height="16" className={PHASE_FILL[PHASE_KEYS.indexOf(p.key)] ?? "text-chart-1"} fill="currentColor">
              <title>{`${p.label} ${fmtSecs(p.s)}`}</title>
            </rect>
          );
          x += w;
          return el;
        })}
      </svg>
      <span>{fmtDurShort(total)}</span>
    </span>
  );
}

/** the six phases once, above a table of phase bars: the colour of each segment */
export function PhaseLegend() {
  return (
    <ul aria-label="Phases" className="m-0 mb-2 flex list-none flex-wrap items-center gap-x-4 gap-y-1 p-0 text-xs leading-4 text-muted-foreground">
      {PHASES.map((p, i) => (
        <li key={p.key} className="inline-flex items-center gap-1.5">
          <svg aria-hidden="true" width="10" height="10" className={PHASE_FILL[i]}><rect width="10" height="10" rx="2" fill="currentColor" /></svg>{p.label}
        </li>
      ))}
    </ul>
  );
}

/** our own 80 x 24 sparkline; nulls break the path */
export function Sparkline({ values, className }: { values: (number | null)[]; className?: string }) {
  const nums = values.filter((v): v is number => v != null);
  if (nums.length < 2) return <svg aria-hidden="true" width="80" height="24" className={className} />;
  const min = Math.min(...nums), max = Math.max(...nums), span = max - min || 1;
  let d = "", pen = false;
  values.forEach((v, i) => {
    if (v == null) { pen = false; return; }
    const x = (i / (values.length - 1)) * 80, y = 22 - ((v - min) / span) * 20;
    d += `${pen ? "L" : "M"}${x.toFixed(1)} ${y.toFixed(1)}`; pen = true;
  });
  return <svg aria-hidden="true" width="80" height="24" className={cn("text-chart-1", className)}><path d={d} fill="none" stroke="currentColor" strokeWidth="1.25" /></svg>;
}
