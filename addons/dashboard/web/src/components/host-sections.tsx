// The Server page's observability: sections like a cloud VM's monitoring tab. Each folds; each
// chart draws when it nears the viewport (components/lazy.tsx). One ChartSpec in lib/observe.ts
// describes a chart; this file turns it into points, an axis and a card.
import { memo, useMemo } from "react";
import { CARD_H, CARD_MULTI_H, ChartCard } from "./chart-card";
import { Fold, Lazy } from "./lazy";
import { PanelBoundary } from "./panel";
import { extPoints, FMT, HOST_SECTIONS, multiPoints, pctPoints, type ChartSpec } from "@/lib/observe";
import { chartDomain, cpuMax, describe, hostPoints, lastValue, memoryTicks, niceMax, RANGE_S, roundTicks, type ChartDomain, type ChartPoint, type HostKey, type RangeKey } from "@/lib/shape";
import { fmtBytes } from "@/lib/format";
import type { HostMetrics, Snapshot } from "@/lib/types";

const SpecChart = memo(function SpecChart({ spec, m, cpus, range, domain }: { spec: ChartSpec; m: HostMetrics; cpus: number | null; range: RangeKey; domain: ChartDomain }) {
  const fmt = FMT[spec.fmt];
  const calc = useMemo(() => {
    const one = (s: { g: string; key: string; unit?: "raw" | "perSec" | "perMin"; div?: number }): ChartPoint[] =>
      s.g === "series" ? hostPoints(m.series, s.key as HostKey) : extPoints(m, s.g as "extended" | "monitoring", s.key as never, s.unit, s.div);
    const points: ChartPoint[] = spec.lines ? multiPoints(spec.lines.map((l) => one(l.src)), !!spec.stack)
      : spec.pctOf ? pctPoints(m.series, spec.pctOf.used, spec.pctOf.total) : spec.src ? one(spec.src) : [];
    const max = describe(points).max;
    let limit: number | null = null, limitLabel: string | undefined;
    if (spec.limit === "cores" && cpus) { limit = cpus; limitLabel = `${cpus} ${cpus === 1 ? "core" : "cores"}`; }
    if (spec.limit === "memTotal") { limit = lastValue(m.series, "memory_total_bytes"); if (limit) limitLabel = `total ${fmtBytes(limit)}`; }
    let y: number;
    if (spec.yMax === "full") y = 100;
    else if (spec.yMax === "pct") y = cpuMax(max);
    else if (spec.yMax?.startsWith("total:")) {
      const tot = m.extended?.swap_total_bytes?.filter((x): x is number => x != null).at(-1) ?? 0;
      y = tot > 0 ? tot : niceMax(max);
    } else y = niceMax(Math.max(max ?? 0, limit ?? 0));
    const yTicks = spec.fmt === "bytes" ? memoryTicks(y) : roundTicks(y);
    return { points, y, yTicks, limit, limitLabel };
  }, [spec, m, cpus]);
  return (
    <ChartCard title={spec.title} name={spec.title} note={spec.note} range={range} span={RANGE_S[range]} metrics={m} deploys={0} kind="area"
      points={calc.points} domain={domain} yMax={calc.y} yTicks={calc.yTicks} color={spec.color ?? "var(--chart-1)"} fmt={fmt}
      lines={spec.lines?.map((l) => ({ name: l.name, color: l.color }))} stack={spec.stack}
      limit={calc.limit} limitLabel={calc.limitLabel} syncId={`host-${spec.id}-${range}`} />
  );
});

export function HostSections({ m, d, range }: { m: HostMetrics; d: Snapshot; range: RangeKey }) {
  const domain = useMemo(() => chartDomain(range, d.server_now, m), [range, d.server_now, m]);
  const cpus = d.system?.cpus ?? null;
  return (
    <>
      {HOST_SECTIONS.map((sec, si) => (
        <Fold key={sec.id} title={sec.title} count={sec.charts.length}>
          <div className="grid grid-cols-1 gap-3 min-[1280px]:grid-cols-2">
            {sec.charts.map((c) => {
              const chart = <PanelBoundary minH="h-[200px]"><SpecChart spec={c} m={m} cpus={cpus} range={range} domain={domain} /></PanelBoundary>;
              // the first section is above the fold: drawn at once; the rest when they near the viewport
              return si === 0 ? <div key={c.id} className="min-w-0">{chart}</div>
                : <Lazy key={c.id} h={c.lines ? CARD_MULTI_H : CARD_H}>{chart}</Lazy>;
            })}
          </div>
        </Fold>
      ))}
    </>
  );
}
