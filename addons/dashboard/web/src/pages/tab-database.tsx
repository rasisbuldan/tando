// The Database tab of an app that has a database (lazy chunk): connections, transactions, rows,
// cache, deadlocks, temp files, long transactions, size and growth, the top queries, and the
// button that opens the studio. Data: the app snapshot's `database` (series, latest, top_queries).
import { useMemo } from "react";
import { Card } from "@/components/ui/card";
import { RangeTabs } from "@/components/ui/tabs";
import { Table, Td, Th, Tr } from "@/components/ui/table";
import { CARD_MULTI_H, ChartCard } from "@/components/chart-card";
import { Lazy } from "@/components/lazy";
import { MetricCard } from "@/components/bits";
import { Empty, PanelBoundary, Section } from "@/components/panel";
import { StudioButton } from "@/components/studio";
import { cpuMax, chartDomain, describe, memoryTicks, niceMax, RANGE_S, roundTicks, type RangeKey } from "@/lib/shape";
import { DB_CHARTS, dbGrowthPerDay, dbPoints, FMT, multiPoints, queryRows, wrapNote, type DbChartSpec } from "@/lib/observe";
import { DASH, fmtBytes, fmtNum, fmtPct, fmtSecs } from "@/lib/format";
import type { AppDetail, DbPoint, Snapshot } from "@/lib/types";

const nf = new Intl.NumberFormat("en-GB", { maximumFractionDigits: 2 });

const DbChart = ({ spec, series, m, domain, range, maxConns }: { spec: DbChartSpec; series: DbPoint[]; m: AppDetail["metrics"]; domain: { from: number; to: number }; range: RangeKey; maxConns: number | null }) => {
  const calc = useMemo(() => {
    const points = multiPoints(spec.lines.map((l) => dbPoints(series, l.key)), !!spec.stack);
    const max = describe(points).max;
    const limit = spec.limit === "max_connections" ? maxConns : null;
    const y = spec.yMax === "full" ? 100 : spec.fmt === "pct" ? cpuMax(max) : niceMax(Math.max(max ?? 0, limit ?? 0));
    return { points, y, ticks: spec.fmt === "bytes" ? memoryTicks(y) : roundTicks(y), limit };
  }, [spec, series, maxConns]);
  const single = spec.lines.length === 1;
  return (
    <ChartCard title={spec.title} name={spec.title} note={spec.note} range={range} span={RANGE_S[range]} metrics={m} deploys={0} kind="area" points={calc.points} domain={domain}
      yMax={calc.y} yTicks={calc.ticks} color={spec.lines[0].color} fmt={FMT[spec.fmt]} lines={single ? undefined : spec.lines.map((l) => ({ name: l.name, color: l.color }))} stack={spec.stack}
      limit={calc.limit} limitLabel={calc.limit != null ? `max ${calc.limit}` : undefined} syncId={`db-${range}`} />
  );
};

export default function DatabaseTab({ host, app, d, v, range, setRange }: { host: string; app: string; d: AppDetail | undefined; v: Snapshot; range: RangeKey; setRange: (r: RangeKey) => void }) {
  const db = d?.database ?? null;
  const series = db?.series;
  const latest = db?.latest ?? null;
  const m = d?.metrics ?? null;
  const domain = useMemo(() => chartDomain(range, v.server_now, m), [range, v.server_now, m]);
  const queries = useMemo(() => queryRows(db?.top_queries), [db?.top_queries]);
  const growth = useMemo(() => dbGrowthPerDay(series ?? []), [series]);
  const maxConns = latest?.max_connections ?? db?.connection_limit ?? null;
  const open = latest ? (latest.active ?? 0) + (latest.idle ?? 0) + (latest.idle_in_transaction ?? 0) + (latest.waiting ?? 0) : db?.connections ?? null;
  const size = latest?.size_bytes ?? db?.bytes ?? null;
  const wrap = wrapNote(latest?.wraparound_pct);
  const anyData = !!series && series.some((p) => Object.entries(p).some(([k, x]) => k !== "t" && x != null));
  return (
    <>
      <div className="mb-4 flex flex-wrap items-center justify-between gap-2">
        <RangeTabs label="Range" value={range} onChange={setRange} items={["1h", "24h", "7d"] as RangeKey[]} />
        <StudioButton host={host} app={app} />
      </div>
      {!db ? <Empty>No database numbers yet. They appear a few minutes after the database is created.</Empty> : (
        <>
          <div className="mb-4 grid grid-cols-1 gap-3 min-[641px]:grid-cols-2 min-[1024px]:grid-cols-4">
            <MetricCard label="Size" value={fmtBytes(size)} sub={growth != null ? `${growth >= 0 ? "+" : "-"}${fmtBytes(Math.abs(growth))} a day` : "growth needs two readings"} />
            <MetricCard label="Connections" value={open ?? DASH} sub={maxConns != null ? `of ${maxConns} allowed` : undefined} />
            <MetricCard label="Longest transaction" value={fmtSecs(latest?.longest_transaction_s)} sub={`idle in transaction ${fmtSecs(latest?.longest_idle_in_transaction_s)}`} />
            <MetricCard label="Wraparound" value={fmtPct(latest?.wraparound_pct)} sub={latest?.xid_age != null ? `transaction age ${fmtNum(latest.xid_age)}` : "of the safe range"} />
          </div>
          {wrap && <p role="status" className="mb-4 rounded-lg border border-warn-border bg-warn-bg p-3 text-[13px]">{wrap}</p>}
          {!anyData ? <Empty>No history yet. The server reads the database once a minute.</Empty> : (
            <div className="mb-4 grid grid-cols-1 gap-3 min-[1280px]:grid-cols-2">
              {DB_CHARTS.map((c, i) => {
                const chart = <PanelBoundary minH="h-[200px]"><DbChart spec={c} series={series!} m={m} domain={domain} range={range} maxConns={maxConns} /></PanelBoundary>;
                return i < 2 ? <div key={c.id} className="min-w-0">{chart}</div> : <Lazy key={c.id} h={CARD_MULTI_H}>{chart}</Lazy>;
              })}
            </div>
          )}
          <Section title="Top queries" aside={db.top_queries?.queries.length ? <span className="text-xs text-muted-foreground">by total time, from pg_stat_statements</span> : null}>
            {queries.length === 0 ? <Empty>No query statistics. Turn on pg_stat_statements for this database to see the slowest queries here.</Empty> : (
              <div className="overflow-x-auto rounded-lg border border-border bg-card">
                <Table className="min-w-[760px]">
                  <thead><tr><Th>Query</Th><Th className="w-[90px] text-right">Calls</Th><Th className="w-[100px] text-right">Mean</Th><Th className="w-[110px] text-right">Total</Th><Th className="w-[90px] text-right">Rows</Th></tr></thead>
                  <tbody>{queries.map((q) => (
                    <Tr key={q.full}>
                      <Td className="max-w-0"><span className="mono block truncate" title={q.full}>{q.text}</span></Td>
                      <Td className="text-right">{q.calls == null ? DASH : nf.format(q.calls)}</Td>
                      <Td className="text-right">{q.meanMs == null ? DASH : `${nf.format(q.meanMs)} ms`}</Td>
                      <Td className="text-right">{q.totalMs == null ? DASH : fmtSecs(q.totalMs / 1000)}</Td>
                      <Td className="text-right">{q.rows == null ? DASH : nf.format(q.rows)}</Td>
                    </Tr>))}</tbody>
                </Table>
              </div>
            )}
          </Section>
          <Card className="text-xs text-muted-foreground">Read once a minute. Rates are per second; the studio opens read-only. Times are the server&apos;s clock, GMT.</Card>
        </>
      )}
    </>
  );
}
