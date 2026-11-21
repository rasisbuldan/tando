// App tabs fed by the extra reads: Traffic, Jobs, Env, What changed. One lazy chunk.
import { useMemo, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { RangeTabs } from "@/components/ui/tabs";
import { Select } from "@/components/ui/select";
import { Table, Td, Th, Tr } from "@/components/ui/table";
import { Tip } from "@/components/ui/tooltip";
import { ChartCard } from "@/components/chart-card";
import { Age, Command, Missing, Mono, MetricCard, PhaseBar, PhaseLegend, Sparkline } from "@/components/bits";
import { Empty, Section } from "@/components/panel";
import { ExtraBody } from "@/components/extra-body";
import { cn } from "@/lib/cn";
import { extraPoller } from "@/lib/extra";
import { usePoller } from "@/lib/resources";
import { chartDomain, describe, niceMax, phases, resultKind, roundTicks, type RangeKey } from "@/lib/shape";
import {
  changesBetween, classShares, cleanNote, defaultPair, envAction, envKeys, envRows, envTime, errorGroups, jobRuns, jobsOrder, jobState, perMinute,
  runBars, slowestPaths, splitPath, type Job, type Requests,
} from "@/lib/pages";
import { DASH, fmtDateTime, fmtDurShort, fmtMs, fmtSecs, shortId } from "@/lib/format";
import type { AppDetail } from "@/lib/types";
import { Act, blocked, useSlot, type AppCtx } from "@/components/actions";
import { actions } from "@/lib/actions";

interface TabProps { host: string; app: string; d: AppDetail | undefined; nowS: number; ctx?: AppCtx | null }

// ---------------- Traffic ----------------
const CLASS_FILL: Record<string, string> = { "1xx": "text-faint", "2xx": "text-chart-1", "3xx": "text-chart-3", "4xx": "text-chart-2", "5xx": "text-chart-6" };
const nf = new Intl.NumberFormat("en-GB");

export function TrafficTab({ host, app }: TabProps) {
  const [range, setRange] = useState<RangeKey>("1h");
  const st = usePoller(extraPoller("requests", host, app, range));
  const eg = usePoller(extraPoller("errors", host, app));
  return (
    <>
      <div className="mb-4"><RangeTabs label="Range" value={range} onChange={setRange} items={["1h", "24h", "7d"] as RangeKey[]} /></div>
      <ExtraBody st={st} what="requests" h="h-96">{(r) => <RequestsBody r={r} range={range} />}</ExtraBody>
      <Section title="Error groups" aside={<span className="text-xs text-muted-foreground">last 7 days, per hour</span>}>
        <ExtraBody st={eg} what="errors">{(e) => {
          const groups = errorGroups(e);
          if (groups.length === 0) return <Empty>No errors in the logs. Groups appear when the app logs an error.</Empty>;
          return (
            <div className="overflow-x-auto rounded-lg border border-border bg-card">
              <Table className="min-w-[860px]">
                <thead><tr><Th>Error</Th><Th className="w-[70px] text-right">Count</Th><Th className="w-[140px]">First seen</Th><Th className="w-[140px]">Last seen</Th><Th className="w-[150px]">Release</Th><Th className="w-[104px]">7 days</Th></tr></thead>
                <tbody>{groups.map((g) => (
                  <Tr key={g.id}>
                    <Td><Tip text={g.title ?? g.label ?? g.id}><span>{g.label ?? g.title ?? g.id}</span></Tip>{g.title && g.label && g.title !== g.label && <span className="text-muted-foreground"> · {g.title}</span>}</Td>
                    <Td className="text-right">{nf.format(g.count)}{g.total != null && g.total !== g.count && <span className="text-muted-foreground"> of {nf.format(g.total)}</span>}</Td>
                    <Td>{fmtDateTime(g.first_seen)}</Td><Td>{fmtDateTime(g.last_seen)}</Td>
                    <Td>{g.release ? <Tip text={g.release}><Mono>{shortId(g.release)}</Mono></Tip> : <Missing />}</Td>
                    <Td><Sparkline values={g.spark} className="text-chart-6" /></Td>
                  </Tr>
                ))}</tbody>
              </Table>
            </div>
          );
        }}</ExtraBody>
      </Section>
    </>
  );
}

function RequestsBody({ r, range }: { r: Requests; range: RangeKey }) {
  const pts = useMemo(() => perMinute(r), [r]);
  const shares = useMemo(() => classShares(r), [r]);
  const paths = useMemo(() => slowestPaths(r), [r]);
  const domain = useMemo(() => (r.to != null ? { from: r.from ?? r.to - r.window_s, to: r.to } : chartDomain(range, null, null)), [r, range]);
  const peak = describe(pts).max;
  const yMax = niceMax(peak);
  const ticks = useMemo(() => roundTicks(yMax), [yMax]);
  if (!r.total) return <Section title="Requests"><Empty>No requests in this window. Open the app&apos;s link to see them here.</Empty></Section>;
  return (
    <>
      <div className="mb-4 grid grid-cols-1 gap-3 min-[641px]:grid-cols-2 min-[1024px]:grid-cols-4">
        <MetricCard label="Requests" value={nf.format(r.total)} sub={`in ${fmtDurShort(r.window_s)}${r.avg_ms != null ? ` · avg ${fmtMs(r.avg_ms)}` : ""}`} />
        <MetricCard label="p50" value={fmtMs(r.p50_ms)} sub="median" />
        <MetricCard label="p95" value={fmtMs(r.p95_ms)} sub={`slowest 5%`} />
        <MetricCard label="p99" value={fmtMs(r.p99_ms)} sub={r.max_ms != null ? `max ${fmtMs(r.max_ms)}` : "slowest 1%"} />
      </div>
      <Section title="Status classes">
        <Card>
          <svg role="img" aria-label={`Status classes: ${shares.map((s) => `${s.cls} ${s.n}`).join(", ")}`} width="100%" height="16" viewBox="0 0 1000 16" preserveAspectRatio="none" className="mb-3 block rounded-sm">
            {(() => { let x = 0; return shares.map((s) => { const w = Math.max(4, s.pct * 10); const el = <rect key={s.cls} x={x} y="0" width={Math.max(0, w - 2)} height="16" className={CLASS_FILL[s.cls]} fill="currentColor"><title>{`${s.cls} ${nf.format(s.n)}`}</title></rect>; x += w; return el; }); })()}
          </svg>
          <ul className="m-0 flex list-none flex-wrap gap-x-6 gap-y-1 p-0 text-[13px]">
            {shares.map((s) => (
              <li key={s.cls} className="inline-flex items-center gap-2"><svg aria-hidden="true" width="10" height="10" className={CLASS_FILL[s.cls]}><rect width="10" height="10" rx="2" fill="currentColor" /></svg>
                <span>{s.cls}</span><span className="font-medium">{nf.format(s.n)}</span><span className="text-muted-foreground">{s.pct < 10 ? s.pct.toFixed(1) : Math.round(s.pct)}%</span></li>
            ))}
          </ul>
        </Card>
      </Section>
      <div className="mb-4">
        <ChartCard title="Requests per minute" name="Requests" range={range} span={Math.max(60, domain.to - domain.from)} metrics={null} deploys={0} kind="area" points={pts} domain={domain}
          yMax={yMax} yTicks={ticks} color="var(--chart-1)" second={{ name: "5xx", color: "var(--chart-6)" }} fmt={(n) => `${n < 10 ? n.toFixed(1) : Math.round(n)}/min`} fmtTick={(n) => (n % 1 ? n.toFixed(1) : String(n))} />
        <p className="m-0 mt-1 text-xs text-muted-foreground">Total in blue, 5xx in vermillion. Latency per minute is not in the data, only the window&apos;s p50, p95 and p99 above.</p>
      </div>
      <Section title="Slowest paths">
        {paths.length === 0 ? <Empty>No paths in this window.</Empty> : (
          <div className="overflow-x-auto rounded-lg border border-border bg-card">
            <Table className="min-w-[640px]">
              <thead><tr><Th>Path</Th><Th className="w-[90px] text-right">Count</Th><Th className="w-[100px] text-right">Mean</Th><Th className="w-[100px] text-right">Max</Th><Th className="w-[90px] text-right">5xx</Th></tr></thead>
              <tbody>{paths.map((p) => { const sp = splitPath(p.path); return (
                <Tr key={p.path}>
                  <Td><Tip text={p.path}><span className="mono">{sp.method && <span className="text-muted-foreground">{sp.method} </span>}{sp.path}</span></Tip></Td>
                  <Td className="text-right">{nf.format(p.count)}</Td><Td className="text-right">{fmtMs(p.mean_ms)}</Td><Td className="text-right">{fmtMs(p.max_ms)}</Td>
                  <Td className={cn("text-right", !!p.count_5xx && "text-fail")}>{p.count_5xx ? nf.format(p.count_5xx) : DASH}</Td>
                </Tr>); })}</tbody>
            </Table>
          </div>
        )}
      </Section>
    </>
  );
}

// ---------------- Jobs ----------------
const BAR_FILL: Record<string, string> = { ok: "text-ok", fail: "text-fail", warn: "text-warn", neutral: "text-neutral", stale: "text-stale", info: "text-info" };

function RunBars({ job, tallest }: { job: Job; tallest: number }) {
  const bars = runBars(jobRuns(job), tallest);
  if (bars.length === 0) return <Missing />;
  const W = 6, G = 2;
  return (
    <svg role="img" aria-label={`${bars.length} past ${bars.length === 1 ? "run" : "runs"}: ${bars.map((b) => `${b.word} ${fmtSecs(b.duration_s)}`).join(", ")}`} width={bars.length * (W + G)} height="24" className="block">
      {bars.map((b, i) => (
        <rect key={b.at} x={i * (W + G)} y={24 - Math.round(b.h * 24)} width={W} height={Math.round(b.h * 24)} className={BAR_FILL[b.result]} fill="currentColor">
          <title>{`${fmtDateTime(b.at)}: ${b.word}, ${fmtSecs(b.duration_s)}`}</title>
        </rect>
      ))}
    </svg>
  );
}

export function JobsTab({ host, app, nowS }: TabProps) {
  const st = usePoller(extraPoller("jobs", host, app));
  const [open, setOpen] = useState<string | null>(null);
  return (
    <Section title="Jobs">
      <ExtraBody st={st} what="jobs">{(j) => {
        if (j.jobs.length === 0) return <Empty>No jobs. Add one under <code>[jobs]</code> in tando.conf.</Empty>;
        const jobs = jobsOrder(j.jobs);
        const tallest = Math.max(0, ...jobs.flatMap((x) => jobRuns(x).map((r) => r.duration_s ?? 0)));
        return (
          <>
            <div className="overflow-x-auto rounded-lg border border-border bg-card">
              <Table className="min-w-[960px]">
                <thead><tr><Th className="w-[130px]">Job</Th><Th className="w-[130px]">Schedule</Th><Th className="w-[80px]">State</Th><Th className="w-[250px]">Next run</Th><Th className="w-[110px]">Last result</Th><Th className="w-[90px]">Duration</Th><Th>Past runs</Th><Th className="w-[84px]"><span className="sr-only">Details</span></Th></tr></thead>
                <tbody>{jobs.map((x) => {
                  const s = jobState(x.state), r = resultKind(x.result), isOpen = open === x.name;
                  return (
                    <JobRows key={x.name} open={isOpen} cols={8} detail={<JobDetail job={x} zone={j.zone_name ?? j.zone} />}>
                      <Td><Mono>{x.name}</Mono></Td>
                      <Td><Mono>{x.schedule ?? DASH}</Mono></Td>
                      <Td><Badge kind={s.kind}>{s.word}</Badge></Td>
                      <Td>{x.next_run != null ? <>{fmtDateTime(x.next_run)}<span className="text-muted-foreground"> · in {fmtDurShort(x.next_run - nowS)}</span></> : <Missing />}</Td>
                      <Td>{x.result ? <Badge kind={r.kind}>{r.word}</Badge> : <Missing />}</Td>
                      <Td>{fmtSecs(x.duration_s)}</Td>
                      <Td><RunBars job={x} tallest={tallest} /></Td>
                      <Td><Button variant="ghost" aria-expanded={isOpen} onClick={() => setOpen(isOpen ? null : x.name)}>{isOpen ? "Hide" : "Runs"}</Button></Td>
                    </JobRows>
                  );
                })}</tbody>
              </Table>
            </div>
            <p className="m-0 mt-2 text-xs text-muted-foreground">Bars are runs, oldest first, as tall as they took, coloured by result. Times are GMT.</p>
          </>
        );
      }}</ExtraBody>
    </Section>
  );
}
function JobRows({ children, open, detail, cols }: { children: React.ReactNode; open: boolean; detail: React.ReactNode; cols: number }) {
  return <><Tr>{children}</Tr>{open && <tr className="border-t border-border bg-muted/40"><td colSpan={cols} className="px-3 py-2">{detail}</td></tr>}</>;
}
function JobDetail({ job, zone }: { job: Job; zone: string | null }) {
  const runs = jobRuns(job);
  return (
    <div className="grid gap-3 text-[13px] min-[900px]:grid-cols-2">
      <div>
        <div className="mb-1 text-xs font-medium text-muted-foreground">Past runs</div>
        {runs.length === 0 ? <span className="text-muted-foreground">No runs yet.</span> : (
          <Table><tbody>{runs.map((r) => { const k = resultKind(r.result); return (
            <tr key={r.at} className="h-8"><td className="w-[170px] pr-3">{fmtDateTime(r.at)}</td><td className="w-[110px] pr-3"><Badge kind={k.kind}>{k.word}</Badge></td><td>{fmtSecs(r.duration_s)}</td></tr>); })}</tbody></Table>
        )}
        {!job.runs?.length && <p className="m-0 mt-1 text-xs text-muted-foreground">tando keeps the last run of each job; earlier runs show here when the server sends them.</p>}
      </div>
      <div>
        <div className="mb-1 text-xs font-medium text-muted-foreground">Command</div>
        <div className="mb-2 break-all">{job.command ? <Mono>{job.command}</Mono> : <Missing />}{job.exit_code != null && job.exit_code !== 0 && <span className="text-muted-foreground"> · exit {job.exit_code}</span>}</div>
        <div className="mb-1 text-xs font-medium text-muted-foreground">Next runs{zone ? ` (${zone})` : ""}</div>
        {job.next_runs.length === 0 ? <span className="text-muted-foreground">None: the job is paused.</span> : <ul className="m-0 list-none p-0">{job.next_runs.map((n) => <li key={n}>{n}</li>)}</ul>}
      </div>
    </div>
  );
}

// ---------------- Env ----------------
function SetVariable({ ctx }: { ctx: AppCtx }) {
  const slot = useSlot(ctx.host, ctx.app);
  return <Act why={blocked(ctx, slot, "env-set", null)} variant="primary" onClick={() => actions().open(ctx.host, ctx.app, "env-set")}>Set variable</Act>;
}

export function EnvTab({ host, app, nowS, ctx }: TabProps) {
  const names = usePoller(extraPoller("envnames", host, app));
  const log = usePoller(extraPoller("envlog", host, app));
  const rows = useMemo(() => envRows(names.data?.names, log.data?.entries), [names.data, log.data]);
  return (
    <>
      {ctx && <div className="mb-3"><SetVariable ctx={ctx} /></div>}
      <Section title="Names" aside={<span className="text-xs text-muted-foreground">values are never shown</span>}>
        <ExtraBody st={names} what="env names">{(n) => n.names.length === 0 ? <Empty>No variables. Set one with <Command cmd={`tando env set KEY -H ${host}`} /></Empty> : (
          <div className="overflow-x-auto rounded-lg border border-border bg-card">
            <Table className="min-w-[640px]">
              <thead><tr><Th className="w-[260px]">Name</Th><Th className="w-[130px]">Last changed</Th><Th className="w-[110px]">By</Th><Th>Note</Th></tr></thead>
              <tbody>{rows.map((r) => (
                <Tr key={r.key}><Td><Mono>{r.key}</Mono></Td><Td><Age t={r.changedAt} nowS={nowS} /></Td><Td>{r.by ?? <Missing />}</Td><Td className="text-muted-foreground">{r.note ?? <Missing />}</Td></Tr>
              ))}</tbody>
            </Table>
          </div>
        )}</ExtraBody>
      </Section>
      <Section title="Change log">
        <ExtraBody st={log} what="the env change log">{(l) => l.entries.length === 0 ? <Empty>No env changes recorded.</Empty> : (
          <div className="overflow-x-auto rounded-lg border border-border bg-card">
            <Table className="min-w-[760px]">
              <thead><tr><Th className="w-[150px]">Time</Th><Th className="w-[90px]">Action</Th><Th>Names</Th><Th className="w-[100px]">By</Th><Th className="w-[240px]">Note</Th></tr></thead>
              <tbody>{[...l.entries].sort((a, b) => (envTime(b.time) ?? 0) - (envTime(a.time) ?? 0) || b.n - a.n).map((e) => (
                <Tr key={e.n}>
                  <Td>{envTime(e.time) != null ? fmtDateTime(envTime(e.time)) : e.time}</Td>
                  <Td>{envAction(e)}</Td>
                  <Td><Tip text={envKeys(e).map((k) => `${k.op} ${k.key}`).join(", ")}><span className="mono">{envKeys(e).map((k) => `${k.op === "added" ? "+" : k.op === "removed" ? "-" : "~"}${k.key}`).join(" ")}</span></Tip></Td>
                  <Td>{e.by ?? <Missing />}</Td>
                  <Td className="text-muted-foreground">{cleanNote(e.note) ?? <Missing />}</Td>
                </Tr>
              ))}</tbody>
            </Table>
          </div>
        )}</ExtraBody>
      </Section>
    </>
  );
}

// ---------------- What changed ----------------
export function ChangesTab({ host, app, d }: TabProps) {
  const log = usePoller(extraPoller("envlog", host, app));
  const releases = d?.releases ?? [];
  const def = useMemo(() => defaultPair(releases), [releases]);
  const [pick, setPick] = useState<{ from: string; to: string } | null>(null);
  const from = pick?.from ?? def?.from ?? "", to = pick?.to ?? def?.to ?? "";
  const ch = useMemo(() => changesBetween(releases, d?.history ?? [], log.data?.entries, from, to), [releases, d?.history, log.data, from, to]);
  if (!d) return <Empty>Loading the releases…</Empty>;
  if (releases.length < 2) return <Empty>Only one release so far. Deploy again to compare.</Empty>;
  const opts = releases.map((r): [string, string] => [r.id, `${r.id}${r.current ? " (live)" : ""}`]);
  return (
    <>
      <div className="mb-4 flex flex-wrap items-center gap-2 text-[13px]">
        <span className="text-muted-foreground">From</span>
        <Select label="From release" value={from} onChange={(v) => setPick({ from: v, to })} options={opts} className="w-56" />
        <span className="text-muted-foreground">to</span>
        <Select label="To release" value={to} onChange={(v) => setPick({ from, to: v })} options={opts} className="w-56" />
      </div>
      {ch.empty && log.data && <Empty>Nothing changed between these releases.</Empty>}
      {(!ch.empty || !log.data) && (
        <>
          <Section title="Deploy notes">
            {ch.notes.length === 0 ? <Empty>No notes on the deploys in between.</Empty> : (
              <ul className="m-0 list-none divide-y divide-border overflow-hidden rounded-lg border border-border bg-card p-0">
                {ch.notes.map((h) => <li key={`${h.at}-${h.release}`} className="flex min-h-9 items-center gap-3 px-3 text-[13px]"><span className="w-[130px] shrink-0 text-muted-foreground">{fmtDateTime(h.at)}</span><Mono className="shrink-0">{shortId(h.release)}</Mono><span className="min-w-0 flex-1">{h.note}</span></li>)}
              </ul>
            )}
          </Section>
          <Section title="Env changes" aside={<span className="text-xs text-muted-foreground">names only</span>}>
            <ExtraBody st={log} what="the env change log">{() => ch.env.length === 0 ? <Empty>No env changes in between.</Empty> : (
              <div className="overflow-x-auto rounded-lg border border-border bg-card">
                <Table className="min-w-[640px]">
                  <thead><tr><Th className="w-[150px]">Time</Th><Th className="w-[90px]">Action</Th><Th>Names</Th><Th className="w-[100px]">By</Th><Th className="w-[220px]">Note</Th></tr></thead>
                  <tbody>{ch.env.map((e) => (
                    <Tr key={e.n}><Td>{fmtDateTime(envTime(e.time))}</Td><Td>{envAction(e)}</Td>
                      <Td><span className="mono">{envKeys(e).map((k) => `${k.op === "added" ? "+" : k.op === "removed" ? "-" : "~"}${k.key}`).join(" ")}</span></Td>
                      <Td>{e.by ?? <Missing />}</Td><Td className="text-muted-foreground">{cleanNote(e.note) ?? <Missing />}</Td></Tr>
                  ))}</tbody>
                </Table>
              </div>
            )}</ExtraBody>
          </Section>
          <Section title="Deploys between">
            {ch.deploys.length === 0 ? <Empty>No deploys in between.</Empty> : (
              <>
                <PhaseLegend />
                <div className="overflow-x-auto rounded-lg border border-border bg-card">
                  <Table className="min-w-[760px]">
                    <thead><tr><Th className="w-[150px]">Time</Th><Th className="w-[130px]">Release</Th><Th className="w-[84px]">Kind</Th><Th className="w-[104px]">Result</Th><Th className="w-[240px]">Phases</Th><Th>Deployer</Th></tr></thead>
                    <tbody>{ch.deploys.map((h) => { const k = resultKind(h.result); return (
                      <Tr key={`${h.at}-${h.release}-${h.kind}`}><Td>{fmtDateTime(h.at)}</Td><Td><Mono>{shortId(h.release)}</Mono></Td><Td>{h.kind}</Td><Td><Badge kind={k.kind}>{k.word}</Badge></Td>
                        <Td><PhaseBar phases={phases(h)} total={h.total_s} label={phases(h).map((p) => `${p.label} ${fmtSecs(p.s)}`).join(", ") || "no phase times"} /></Td><Td>{h.deployer ?? <Missing />}</Td></Tr>); })}</tbody>
                  </Table>
                </div>
              </>
            )}
          </Section>
        </>
      )}
    </>
  );
}
