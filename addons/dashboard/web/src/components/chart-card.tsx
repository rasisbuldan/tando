import { lazy, Suspense, memo, useMemo, useState } from "react";
import { Card } from "./ui/card";
import { Button } from "./ui/button";
import { Skeleton } from "./ui/skeleton";
import { PanelBoundary } from "./panel";
import { allZero, describe, chartSummary, dataSince, type ChartDomain, type ChartPoint, type RangeKey } from "@/lib/shape";
import { DASH, fmtDateTime } from "@/lib/format";
import type { Metrics } from "@/lib/types";
import type { PlotProps } from "@/charts";

const importCharts = () => import("@/charts");
const Plot = lazy(importCharts);
/** after first data, on idle */
export function prefetchCharts() {
  const f = () => void importCharts();
  if (typeof requestIdleCallback === "function") requestIdleCallback(f); else setTimeout(f, 300);
}

interface Props extends Omit<PlotProps, "span"> {
  title: string; range: RangeKey; span: number; metrics: Pick<Metrics, "data_since" | "bucket_s"> | null; name: string; deploys: number;
  zeroText?: string;   // shown in the plot box when every value is 0 ("No restarts in 24 h")
  note?: string;       // the unit in words, small, under the title row
}

/** height of a card with a legend row (multi-line charts): the lazy placeholder matches it (CLS 0) */
export const CARD_H = "h-[262px]";
export const CARD_MULTI_H = "h-[286px]";

/** Card with a fixed 200 px plot: the skeleton, the empty state and the chart have the same size (CLS 0) */
export const ChartCard = memo(function ChartCard(p: Props) {
  const g = useMemo(() => describe(p.points), [p.points]);
  const since = dataSince(p.metrics, p.domain as ChartDomain);
  const [table, setTable] = useState(false);
  const empty = g.last == null && g.first == null;
  const zero = !empty && !!p.zeroText && allZero(p.points);
  const rows = useMemo(() => {
    const ok = p.points.filter((x) => x.v != null);
    const step = Math.max(1, Math.ceil(ok.length / 24));
    return ok.filter((_, i) => i % step === 0).slice(0, 24);
  }, [p.points]);
  return (
    <Card className="min-w-0">
      <div className="mb-2 flex h-[22px] items-center justify-between gap-2">
        <h3 className="m-0 text-[15px] leading-[22px] font-semibold">{p.title}{p.note && <span className="ml-2 text-xs leading-4 font-normal text-muted-foreground">{p.note}</span>}</h3>
        <div className="flex items-center gap-2 text-xs leading-4 text-muted-foreground">
          {since != null && <span>data since {fmtDateTime(since)}</span>}
          {!empty && !zero && <Button variant="ghost" className="h-6 px-2 text-xs" aria-pressed={table} onClick={() => setTable((t) => !t)}>{table ? "Show chart" : "Show as table"}</Button>}
        </div>
      </div>
      <div className="h-[200px]">
        {empty ? (
          <div className="grid h-full place-items-center rounded-md border border-border text-[13px] text-muted-foreground">No data in this range yet</div>
        ) : zero ? (
          <div className="grid h-full place-items-center rounded-md border border-border text-[13px] text-muted-foreground">{p.zeroText}</div>
        ) : table ? (
          <div className="h-full overflow-y-auto"><table className="w-full text-[13px]">
            {p.lines && <thead><tr><th className="h-6 text-left font-medium text-muted-foreground" />{p.lines.map((l) => <th key={l.name} className="text-right font-medium text-muted-foreground">{l.name}</th>)}</tr></thead>}
            <tbody>{rows.map((r: ChartPoint) => (
              <tr key={r.t} className="border-t border-border"><td className="h-6 text-muted-foreground">{fmtDateTime(r.t)}</td>
                {p.lines ? p.lines.map((l, i) => <td key={l.name} className="text-right">{r.s?.[i] == null ? DASH : p.fmt(r.s[i] as number)}</td>)
                  : <td className="text-right">{r.v == null ? DASH : p.fmt(r.v)}</td>}</tr>))}</tbody></table></div>
        ) : (
          <div role="img" aria-label={chartSummary(p.name, p.range, g, p.fmt, p.deploys)} className="h-full">
            <PanelBoundary minH="h-[200px]">
              <Suspense fallback={<Skeleton className="size-full" />}>
                <Plot {...p} span={p.span} />
              </Suspense>
            </PanelBoundary>
          </div>
        )}
      </div>
      {p.lines && !empty && (
        <ul className="m-0 mt-2 flex h-4 list-none flex-wrap gap-x-4 overflow-hidden p-0 text-xs leading-4 text-muted-foreground">
          {p.lines.map((l) => (
            <li key={l.name} className="inline-flex items-center gap-1.5">
              <svg aria-hidden="true" width="10" height="10"><rect width="10" height="10" rx="2" fill={l.color} /></svg>{l.name}
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
});
