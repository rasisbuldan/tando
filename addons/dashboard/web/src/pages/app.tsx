import { lazy, Suspense, useEffect, useMemo, useState } from "react";
import { NavLink, useParams } from "react-router";
import { Badge } from "@/components/ui/badge";
import { RangeTabs } from "@/components/ui/tabs";
import { Card } from "@/components/ui/card";
import { ChartCard, prefetchCharts } from "@/components/chart-card";
import { HistoryTable, ReleasesTable } from "@/components/history-table";
import { Age, Mono, MetricCard, Sparkline } from "@/components/bits";
import { Empty, Freshness, Loading, PageHeader, Section, SectionError } from "@/components/panel";
import { Table, Td, Th, Tr } from "@/components/ui/table";
import { cn } from "@/lib/cn";
import { refreshAll, snapshotPoller, useNowMs, usePoller } from "@/lib/resources";
import { appKind, chartDomain, cpuMax, deployMarkers, describe, memoryTicks, niceMax, RANGE_S, roundTicks, restartsTotal, stateWithReason, toPoints, uptimeCells, type RangeKey } from "@/lib/shape";
import { AppActions, ProgressPanel, useRollbackTo, type AppCtx } from "@/components/actions";
import { DASH, fmtAgo, fmtBytes, fmtDateTime, fmtDur, fmtMs, fmtPct, fmtTime, pctOf } from "@/lib/format";

const LogsTab = lazy(() => import("./tab-logs"));
const tabs = () => import("./tabs");
const TrafficTab = lazy(() => tabs().then((m) => ({ default: m.TrafficTab })));
const JobsTab = lazy(() => tabs().then((m) => ({ default: m.JobsTab })));
const EnvTab = lazy(() => tabs().then((m) => ({ default: m.EnvTab })));
const ChangesTab = lazy(() => tabs().then((m) => ({ default: m.ChangesTab })));
const TABS = [["overview", "Overview"], ["deploys", "Deploys"], ["logs", "Logs"], ["traffic", "Traffic"], ["jobs", "Jobs"], ["env", "Env"], ["changes", "What changed"]] as const;
const KNOWN = TABS.map((t) => t[0]) as string[];

export default function AppPage() {
  const { host = "", app = "", tab = "overview" } = useParams();
  const [range, setRange] = useState<RangeKey>("24h");
  const r = tab === "overview" ? range : "24h";
  const st = usePoller(snapshotPoller(host, app, r));
  const nowS = Math.floor(useNowMs(30000) / 1000);
  const v = st.data;
  const d = v?.data?.app;
  useEffect(() => { if (v?.data?.app) prefetchCharts(); }, [v?.data?.app]);

  const status = d?.status ?? v?.data?.apps?.find((a) => a.app === app);
  const kind = status ? appKind(status) : null;
  const deployer = d?.history.find((h) => h.release === status?.release)?.deployer;
  const alerts = v?.data?.alerts;
  const ctx = useMemo<AppCtx | null>(() => (status ? {
    host, app, state: status.state_reason ?? null, reachable: !!v?.reachable, origin: d?.origin, releases: d?.releases ?? [], live: status.release ?? null,
  } : null), [host, app, status, v?.reachable, d?.origin, d?.releases]);
  const rb = useRollbackTo(ctx);

  return (
    <>
      <PageHeader
        title={app}
        badge={status && kind ? <Badge kind={v?.reachable ? kind.kind : "stale"}>{v?.reachable ? stateWithReason(status, alerts) : `${kind.word} (stale)`}</Badge> : undefined}
        meta={status ? (
          <>
            {status.release ? <><Mono>{status.release}</Mono> · deployed <Age t={status.deployed_at} nowS={nowS} />{deployer ? ` by ${deployer}` : ""}</> : "never deployed"}
            {status.link && <> · <a href={status.link} target="_blank" rel="noreferrer" className="underline-offset-2 hover:underline">{status.link.replace(/^https?:\/\//, "").replace(/\/$/, "")}</a></>}
            {" · "}<Mono>{host}</Mono>
          </>
        ) : <Mono>{host}</Mono>}
        actions={ctx ? <AppActions ctx={ctx} /> : undefined}
      />
      <Freshness st={st} />
      <ProgressPanel host={host} app={app} />
      <div role="tablist" aria-label="App" className="mb-4 flex h-10 items-end gap-4 overflow-x-auto border-b border-border">
        {TABS.map(([k, label]) => (
          <NavLink key={k} to={`/s/${encodeURIComponent(host)}/${app}/${k}`} role="tab" aria-selected={tab === k}
            className={cn("hov inset-focus flex h-10 items-center border-b-2 text-[13px] leading-5 font-medium whitespace-nowrap", tab === k ? "border-foreground text-foreground" : "border-transparent text-muted-foreground hover:text-foreground")}>{label}</NavLink>
        ))}
      </div>
      {!v && st.error && <SectionError message={st.error.message} onRetry={refreshAll} />}
      {!v && !st.error && <Loading h="h-96" />}
      {v && !v.data && <SectionError message={`${v.error ?? "Not answering"}. Check ssh access, then retry.`} onRetry={refreshAll} />}
      {v?.data && !d && !status && <Empty>No app named <Mono>{app}</Mono> on <Mono>{host}</Mono>.</Empty>}
      {v?.data && !KNOWN.includes(tab) && <Empty>Nothing here. Pick a tab above.</Empty>}
      {v?.data && status && KNOWN.includes(tab) && (
        tab === "overview" ? <OverviewTab d={d} v={v.data} app={app} range={range} setRange={setRange} nowS={nowS} />
          : tab === "deploys" ? (
            <>
              <Section title="Releases">{d ? <ReleasesTable rows={d.releases} rollback={rb} /> : <Loading h="h-24" />}</Section>
              <Section title="History">{d ? <HistoryTable rows={d.history} /> : <Loading h="h-24" />}</Section>
            </>
          ) : (
            <Suspense fallback={<Loading h="h-96" />}>
              {tab === "logs" ? <LogsTab host={host} app={app} releases={(d?.releases ?? []).map((r) => r.id)} />
                : tab === "traffic" ? <TrafficTab host={host} app={app} d={d} nowS={nowS} />
                : tab === "jobs" ? <JobsTab host={host} app={app} d={d} nowS={nowS} />
                : tab === "env" ? <EnvTab host={host} app={app} d={d} nowS={nowS} ctx={ctx} />
                : <ChangesTab host={host} app={app} d={d} nowS={nowS} />}
            </Suspense>
          )
      )}
    </>
  );
}


function OverviewTab({ d, v, app, range, setRange, nowS }: {
  d: import("@/lib/types").AppDetail | undefined; v: import("@/lib/types").Snapshot; app: string; range: RangeKey; setRange: (r: RangeKey) => void; nowS: number;
}) {
  const status = d?.status ?? v.apps?.find((a) => a.app === app)!;
  const m = d?.metrics ?? null;
  const domain = useMemo(() => chartDomain(range, v.server_now, m), [range, v.server_now, m]);
  const mem = useMemo(() => toPoints(m?.series, "memory_bytes"), [m]);
  const cpu = useMemo(() => toPoints(m?.series, "cpu_percent"), [m]);
  const rst = useMemo(() => toPoints(m?.series, "restarts"), [m]);
  const markers = useMemo(() => deployMarkers(d?.history, domain), [d?.history, domain]);
  const cap = status.memory_max_bytes && status.memory_max_bytes > 0 ? status.memory_max_bytes : null;
  const memYMax = cap ?? niceMax(describe(mem).max);
  const memTicks = useMemo(() => memoryTicks(memYMax), [memYMax]);
  const cpuY = cpuMax(describe(cpu).max);
  const cpuTicks = useMemo(() => roundTicks(cpuY), [cpuY]);
  const rstY = Math.max(4, niceMax(describe(rst).max));
  const rstTicks = useMemo(() => roundTicks(rstY), [rstY]);
  const rangeWord = range === "1h" ? "1 h" : range === "24h" ? "24 h" : "7 d";
  const incidents = useMemo(() => (d?.health?.incidents ?? []).map((i) => ({ start: i.start, end: i.end ?? domain.to })), [d?.health, domain.to]);
  const probe = d?.health?.series.points ?? [];
  const probeVals = probe.map((p) => p.avg_ms);
  const probeNums = probeVals.filter((x): x is number => x != null);
  const probeAvg = probeNums.length ? probeNums.reduce((a, b) => a + b, 0) / probeNums.length : null;
  const probeDomain = useMemo(() => chartDomain("24h", v.server_now, null), [v.server_now]);
  const probePoints = useMemo(() => probe.map((p) => ({ t: p.t, v: p.avg_ms })), [probe]);
  const firing = (v.alerts ?? []).filter((a) => a.app === app);
  const cells = useMemo(() => uptimeCells(d?.metrics && range === "24h" ? d.metrics : null, d?.health?.incidents ?? [], domain.to), [d, range, domain.to]);
  const rstTotal = restartsTotal(rst);
  const memNow = status.memory_bytes && status.memory_bytes > 0 ? status.memory_bytes : null;

  return (
    <>
      <div className="mb-4"><RangeTabs label="Range" value={range} onChange={setRange} items={["1h", "24h", "7d"] as RangeKey[]} /></div>
      <div className="mb-4 grid grid-cols-1 gap-3 min-[641px]:grid-cols-2 min-[1024px]:grid-cols-4">
        <MetricCard label="Memory" value={memNow ? fmtBytes(memNow) : DASH} sub={cap && memNow ? `of ${fmtBytes(cap)} · ${fmtPct(pctOf(memNow, cap))}` : "no memory cap"} />
        <MetricCard label="CPU" value={status.cpu_percent != null ? fmtPct(status.cpu_percent) : DASH} sub="last minute" />
        <MetricCard label="Restarts" value={status.restarts ?? DASH} sub={m ? `${rstTotal} in ${range === "1h" ? "1 h" : range === "24h" ? "24 h" : "7 d"} · total ${status.restarts ?? 0}` : "total"} />
        <MetricCard label="Avg probe time" value={probeAvg != null ? fmtMs(probeAvg) : DASH} sub={d?.health ? `24 h · last ${fmtMs(d.health.last_ms)}` : "no health checks"}
          right={<Sparkline values={probeVals} className="mt-1 shrink-0" />} />
      </div>
      {!d || !m ? (
        <Section title="Charts"><Empty>No metrics yet. They appear a few minutes after the first deploy.</Empty></Section>
      ) : (
        <div className="mb-4 grid grid-cols-1 gap-3 min-[1280px]:grid-cols-2">
          <ChartCard title="Memory" name="Memory" range={range} span={RANGE_S[range]} metrics={m} deploys={markers.length} kind="area" points={mem} domain={domain} yMax={memYMax} yTicks={memTicks} color="var(--chart-1)" fmt={fmtBytes} limit={cap} markers={markers} incidents={incidents} syncId="m" />
          <ChartCard title="CPU" name="CPU" range={range} span={RANGE_S[range]} metrics={m} deploys={markers.length} kind="area" points={cpu} domain={domain} yMax={cpuY} yTicks={cpuTicks} color="var(--chart-2)" fmt={fmtPct} markers={markers} syncId="m" />
          <ChartCard title="Restarts" name="Restarts" range={range} span={RANGE_S[range]} metrics={m} deploys={markers.length} kind="bar" zeroText={`No restarts in ${rangeWord}`} points={rst} domain={domain} yMax={rstY} yTicks={rstTicks} color="var(--chart-6)" fmt={(n) => String(Math.round(n))} markers={markers} syncId="m" />
          <ChartCard title="Avg probe time" name="Avg probe time" range="24h" span={RANGE_S["24h"]} metrics={null} deploys={0} kind="area" points={probePoints} domain={probeDomain} yMax={niceMax(Math.max(...probeNums, 0))} color="var(--chart-3)" fmt={fmtMs} />
        </div>
      )}
      <Section title="Uptime and incidents" aside={d?.health ? <span className="text-xs text-muted-foreground">24 h {fmtPct(d.health.uptime_24h_pct)} · 7 d {fmtPct(d.health.uptime_7d_pct)}</span> : null}>
        {!d?.health ? <Empty>No health checks for this app. Add alerts with <code>tando alerts</code>.</Empty> : (
          <Card>
            {cells.length > 0 && (
              <svg role="img" aria-label={`Uptime, last 24 h: ${d.health.incidents.length} incidents`} width="100%" height="16" viewBox={`0 0 ${cells.length} 16`} preserveAspectRatio="none" className="mb-3 block rounded-sm">
                {cells.map((c, i) => <rect key={c.t} x={i} y="0" width="1" height="16" className={c.kind === "fail" ? "text-fail" : c.kind === "ok" ? "text-ok" : "text-border"} fill="currentColor" />)}
              </svg>
            )}
            {d.health.incidents.length === 0 ? <p className="m-0 text-[13px] text-muted-foreground">No incidents.</p> : (
              <Table><thead><tr><Th className="w-[160px] bg-transparent px-0">Start</Th><Th className="w-[110px] bg-transparent">Lasted</Th><Th className="w-[90px] bg-transparent">Check</Th><Th className="bg-transparent">Cause</Th></tr></thead>
                <tbody>{d.health.incidents.map((i) => (
                  <Tr key={i.start}><Td className="px-0">{fmtDateTime(i.start)}</Td><Td>{i.end ? fmtDur(i.end - i.start) : "ongoing"}</Td><Td>{i.check}</Td><Td className="text-muted-foreground">{i.cause ?? DASH}</Td></Tr>
                ))}</tbody></Table>
            )}
          </Card>
        )}
      </Section>
      {d?.database && (
        <Section title="Database">
          <Card className="text-[13px]">
            <Mono>postgres</Mono> · {fmtBytes(d.database.bytes)} · {d.database.connections ?? DASH} of {d.database.connection_limit ?? DASH} connections
          </Card>
        </Section>
      )}
      <Section title="Alerts">
        {firing.length === 0 ? <Empty>No alerts firing.</Empty> : (
          <ul className="m-0 list-none divide-y divide-border overflow-hidden rounded-lg border border-border bg-card p-0">
            {firing.map((a) => (
              <li key={`${a.check}`} className="flex h-9 items-center gap-3 px-3 text-[13px]">
                <Badge kind={a.state === "firing" ? "fail" : "warn"}>{a.state === "firing" ? "firing" : "pending"}</Badge>
                <span className="min-w-0 flex-1 truncate">{a.check}<span className="text-muted-foreground"> · {a.detail ?? DASH}</span></span>
                <span className="shrink-0 text-muted-foreground">{a.since ? `for ${fmtDur(nowS - a.since)}` : DASH}</span>
              </li>
            ))}
          </ul>
        )}
      </Section>
      <p className="m-0 text-xs text-muted-foreground">{d?.metrics ? `Chart times are the server's clock, GMT. Last bucket ${fmtTime(d.metrics.to)} (${fmtAgo(nowS, d.metrics.to)}).` : ""}</p>
    </>
  );
}
