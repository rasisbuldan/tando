// The Recharts chunk: loaded lazily with the first chart (DESIGN 12.2). Animations off, colours
// from CSS variables, no style prop of ours.
import { memo } from "react";
import { Area, AreaChart, Bar, BarChart, CartesianGrid, ReferenceArea, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { markerText, markersNear, type ChartPoint, type ChartDomain, type Marker } from "@/lib/shape";
import { fmtDate, fmtTime } from "@/lib/format";

export interface PlotProps {
  kind: "area" | "bar";
  points: ChartPoint[];
  domain: ChartDomain;
  yMax: number;
  color: string;                 // a CSS variable, e.g. var(--chart-1)
  fmt: (n: number) => string;    // axis + tooltip value
  fmtTick?: (n: number) => string;
  limit?: number | null;         // dashed memory cap (or cores, total)
  limitLabel?: string;           // its label; default "limit <value>"
  markers?: Marker[];
  yTicks?: number[];             // round ticks; the domain stays [0, yMax]
  second?: { name: string; color: string }; // `w` of each point as a second series
  name?: string;
  incidents?: { start: number; end: number }[];
  syncId?: string;
  span: number;                  // range in seconds: picks the tick label format
}

function ticks(d: ChartDomain, n = 5): number[] {
  const step = (d.to - d.from) / (n - 1);
  return Array.from({ length: n }, (_, i) => Math.round(d.from + i * step));
}

function Tip({ active, payload, fmt, markers, near, second, name }: { active?: boolean; payload?: { payload: ChartPoint }[]; fmt: (n: number) => string; markers?: Marker[]; near: number; second?: { name: string }; name?: string }) {
  const p = payload?.[0]?.payload;
  if (!active || !p) return null;
  const ms = markersNear(markers, p.t, near);
  if (p.v == null && ms.length === 0) return null;
  return (
    <div className="rounded-lg border border-border bg-popover p-2 text-xs leading-4 text-foreground shadow-pop">
      <div className="text-muted-foreground">{fmtDate(p.t)} {fmtTime(p.t)}</div>
      {p.v != null && <div className="font-medium">{name ? `${name} ` : ""}{fmt(p.v)}</div>}
      {second && p.w != null && <div className="font-medium">{second.name} {fmt(p.w)}</div>}
      {ms.map((m) => <div key={m.t} className="mono text-muted-foreground">{markerText(m)}</div>)}
    </div>
  );
}

/** the hover target of a deploy marker: a transparent 10 px strip over the dashed line, with a native tooltip */
function MarkerHit({ viewBox, text }: { viewBox?: { x?: number; y?: number; height?: number }; text: string }) {
  if (!viewBox || viewBox.x == null) return null;
  return (
    <rect x={viewBox.x - 5} y={viewBox.y ?? 0} width={10} height={viewBox.height ?? 0} fill="transparent" className="cursor-help">
      <title>{text}</title>
    </rect>
  );
}

function Plot(p: PlotProps) {
  const tick = (t: number) => (p.span > 86400 ? fmtDate(t) : fmtTime(t).replace(" GMT", ""));
  const axis = { stroke: "var(--muted-foreground)", fontSize: 11, tickLine: false, axisLine: false } as const;
  const common = { data: p.points, margin: { top: 8, right: 8, bottom: 0, left: 0 }, syncId: p.syncId };
  const inner = (
    <>
      <CartesianGrid vertical={false} stroke="var(--border)" />
      <XAxis type="number" dataKey="t" domain={[p.domain.from, p.domain.to]} ticks={ticks(p.domain)} tickFormatter={tick} allowDataOverflow {...axis} />
      <YAxis domain={[0, p.yMax]} {...(p.yTicks ? { ticks: p.yTicks } : { tickCount: 4 })} tickFormatter={p.fmtTick ?? p.fmt} width={56} {...axis} />
      <Tooltip content={<Tip fmt={p.fmt} markers={p.markers} near={Math.max(60, p.span / 120)} second={p.second} name={p.name} />} isAnimationActive={false} cursor={{ stroke: "var(--faint)" }} />
      {p.limit != null && <ReferenceLine y={p.limit} stroke="var(--warn)" strokeDasharray="4 4" ifOverflow="extendDomain" label={{ value: p.limitLabel ?? `limit ${p.fmt(p.limit)}`, fill: "var(--warn)", fontSize: 11, position: "insideTopRight" }} />}
      {p.incidents?.map((i) => <ReferenceArea key={i.start} x1={Math.max(i.start, p.domain.from)} x2={Math.min(i.end, p.domain.to)} fill="var(--fail-bg)" fillOpacity={1} />)}
      {p.markers?.map((m) => <ReferenceLine key={`${m.t}-${m.release}`} x={m.t} stroke="var(--faint)" strokeDasharray="3 3" strokeWidth={1} label={<MarkerHit text={markerText(m)} />} />)}
    </>
  );
  return (
    <ResponsiveContainer width="100%" height={200} debounce={50}>
      {p.kind === "bar" ? (
        <BarChart {...common}>{inner}<Bar dataKey="v" fill={p.color} isAnimationActive={false} maxBarSize={8} /></BarChart>
      ) : (
        <AreaChart {...common}>{inner}
          <Area dataKey="v" type="monotone" connectNulls={false} dot={false} activeDot={{ r: 3 }} stroke={p.color} strokeWidth={1.5} fill={p.color} fillOpacity={0.12} isAnimationActive={false} />
          {p.second && <Area dataKey="w" type="monotone" connectNulls={false} dot={false} activeDot={{ r: 3 }} stroke={p.second.color} strokeWidth={1.5} fill={p.second.color} fillOpacity={0.12} isAnimationActive={false} />}
        </AreaChart>
      )}
    </ResponsiveContainer>
  );
}
export default memo(Plot);
