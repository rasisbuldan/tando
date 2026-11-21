import { useEffect, useMemo, useState } from "react";
import { useParams } from "react-router";
import { Play } from "lucide-react";
import { AppsTable } from "@/components/apps-table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { RangeTabs } from "@/components/ui/tabs";
import { ChartCard, prefetchCharts } from "@/components/chart-card";
import { Tip } from "@/components/ui/tooltip";
import { Command, Mono, MetricCard, SshTarget } from "@/components/bits";
import { HostActions, ProgressPanel } from "@/components/actions";
import { Empty, Freshness, Loading, PageHeader, Section, SectionError } from "@/components/panel";
import { refreshAll, snapshotPoller, useDemand, useNowMs, usePoller } from "@/lib/resources";
import { appRows, chartDomain, cpuMax, describe, headroom, hostPoints, lastValue, loadMax, memoryTicks, niceMax, RANGE_S, roundTicks, skewNote, sshTarget, type RangeKey } from "@/lib/shape";
import { DASH, fmtBytes, fmtDur, fmtLoad, fmtPct, fmtTime, pctOf } from "@/lib/format";
import type { DoctorResult, HostMetrics, HostStatus, Snapshot } from "@/lib/types";

function Gauge({ pct, label }: { pct: number | null; label: string }) {
  const w = pct == null ? 0 : Math.max(0, Math.min(100, pct));
  const kind = w >= 90 ? "text-fail" : w >= 80 ? "text-warn" : "text-foreground";
  return (
    <svg role="img" aria-label={label} width="100%" height="8" viewBox="0 0 100 8" preserveAspectRatio="none" className="block rounded-full text-muted">
      <rect width="100" height="8" fill="currentColor" />
      <rect width={w} height="8" className={kind} fill="currentColor" />
    </svg>
  );
}

/** Load, CPU, Memory, Disk over the range: the host's per-minute samples (tando-metrics) */
function HostCharts({ m, d, range }: { m: HostMetrics; d: Snapshot; range: RangeKey }) {
  const domain = useMemo(() => chartDomain(range, d.server_now, m), [range, d.server_now, m]);
  const load = useMemo(() => hostPoints(m.series, "load"), [m]);
  const cpu = useMemo(() => hostPoints(m.series, "cpu_percent"), [m]);
  const mem = useMemo(() => hostPoints(m.series, "memory_used_bytes"), [m]);
  const disk = useMemo(() => hostPoints(m.series, "disk_used_bytes"), [m]);
  const cpus = d.system?.cpus ?? null;
  const memTotal = lastValue(m.series, "memory_total_bytes") ?? d.system?.memory_total_bytes ?? null;
  const diskTotal = lastValue(m.series, "disk_total_bytes") ?? d.system?.disk_total_bytes ?? null;
  const loadY = loadMax(describe(load).max, cpus);
  const loadTicks = useMemo(() => roundTicks(loadY), [loadY]);
  const cpuY = cpuMax(describe(cpu).max);
  const cpuTicks = useMemo(() => roundTicks(cpuY), [cpuY]);
  const memY = memTotal ?? niceMax(describe(mem).max);
  const memT = useMemo(() => memoryTicks(memY), [memY]);
  const diskY = diskTotal ?? niceMax(describe(disk).max);
  const diskT = useMemo(() => memoryTicks(diskY), [diskY]);
  const common = { range, span: RANGE_S[range], metrics: m, deploys: 0, kind: "area" as const, domain, syncId: "host" };
  return (
    <div className="grid grid-cols-1 gap-3 min-[1280px]:grid-cols-2">
      <ChartCard {...common} title="Load" name="Load" points={load} yMax={loadY} yTicks={loadTicks} color="var(--chart-1)" fmt={fmtLoad}
        limit={cpus} limitLabel={cpus ? `${cpus} ${cpus === 1 ? "core" : "cores"}` : undefined} />
      <ChartCard {...common} title="CPU" name="CPU" points={cpu} yMax={cpuY} yTicks={cpuTicks} color="var(--chart-2)" fmt={fmtPct} />
      <ChartCard {...common} title="Memory" name="Memory" points={mem} yMax={memY} yTicks={memT} color="var(--chart-3)" fmt={fmtBytes}
        limit={memTotal} limitLabel={memTotal ? `total ${fmtBytes(memTotal)}` : undefined} />
      <ChartCard {...common} title="Disk" name="Disk" points={disk} yMax={diskY} yTicks={diskT} color="var(--chart-4)" fmt={fmtBytes}
        limit={diskTotal} limitLabel={diskTotal ? `total ${fmtBytes(diskTotal)}` : undefined} />
    </div>
  );
}

export default function ServerPage() {
  const { host = "" } = useParams();
  const [range, setRange] = useState<RangeKey>("24h");
  const st = usePoller(snapshotPoller(host, undefined, range));
  const nowS = Math.floor(useNowMs(30000) / 1000);
  const v = st.data;
  const d = v?.data;
  const s = d?.system;
  const rows = useMemo(() => (v ? appRows([v]) : []), [v]);
  const alertsByHost = useMemo(() => ({ [host]: d?.alerts }), [host, d?.alerts]);
  const doctor = useDemand<DoctorResult>("doctor", host);
  const hs = useDemand<HostStatus>("hoststatus", host);
  const now = useNowMs(1000);
  const cooldown = doctor.ranAtMs ? Math.max(0, 60 - Math.floor((now - doctor.ranAtMs) / 1000)) : 0;
  const skew = skewNote(d?.clock_skew_s);
  const hr = headroom(d?.apps, s?.memory_total_bytes);
  const diskPct = pctOf(s?.disk_used_bytes, s?.disk_total_bytes);
  const memPct = pctOf(s?.memory_used_bytes, s?.memory_total_bytes);
  const hostAlerts = d?.alerts ?? [];
  const hm = d?.host_metrics ?? null;
  useEffect(() => { if (hm) prefetchCharts(); }, [hm]);

  const runDoctor = (
    <Tip text={cooldown ? `Ran ${60 - cooldown} s ago. Again in ${cooldown} s` : "Checks ssh, the agent, disk and Caddy"}>
      <span><Button disabled={doctor.loading || cooldown > 0} onClick={doctor.run}><Play size={16} strokeWidth={1.75} aria-hidden="true" />{doctor.loading ? "Running…" : "Run doctor"}</Button></span>
    </Tip>
  );

  return (
    <>
      <PageHeader
        title={<Mono className="text-xl font-semibold">{host}</Mono>}
        badge={v ? (v.reachable ? <Badge kind="ok">reachable</Badge> : <Badge kind="fail">not answering</Badge>) : undefined}
        meta={d ? <><SshTarget target={sshTarget(d)} className="mr-2 align-middle" />tando {d.server_version ?? DASH} · {skew ?? "clock ok"}{s?.uptime_s ? ` · up ${fmtDur(s.uptime_s)}` : ""}</> : undefined}
        actions={<><HostActions host={host} />{runDoctor}</>}
      />
      <ProgressPanel host={host} app="" />
      <Freshness st={st} />
      {!v && st.error && <SectionError message={st.error.message} onRetry={refreshAll} />}
      {!v && !st.error && <Loading h="h-96" />}
      {v && !v.reachable && (
        <div className="mb-4"><SectionError message={`${host} not answering: ${v.error ?? "ssh failed"}. Check ssh access, then retry.${d ? ` Showing data from ${fmtTime(v.fetchedAtS)}.` : ""}`} onRetry={refreshAll} /></div>
      )}
      {d && s && (
        <>
          <Section title="Load and memory">
            <div className="grid grid-cols-1 gap-3 min-[641px]:grid-cols-2 min-[1024px]:grid-cols-4">
              <MetricCard label="Load (1 min)" value={fmtLoad(s.load_1)} sub={`5 min ${fmtLoad(s.load_5)} · 15 min ${fmtLoad(s.load_15)}`} />
              <MetricCard label="CPUs" value={s.cpus ?? DASH} sub={s.cpus && s.load_1 != null ? `load ${fmtPct((s.load_1 / s.cpus) * 100)} of capacity` : undefined} />
              <MetricCard label="Memory" value={fmtBytes(s.memory_used_bytes)} sub={`of ${fmtBytes(s.memory_total_bytes)} · ${fmtPct(memPct)}`} />
              <MetricCard label="Headroom" value={hr ? fmtPct(hr.pct) : DASH} sub={hr ? `caps ${fmtBytes(hr.capBytes)} of ${fmtBytes(hr.ramBytes)} RAM` : "no memory caps"} />
            </div>
          </Section>
          <Section title="History">
            <div className="mb-4"><RangeTabs label="Range" value={range} onChange={setRange} items={["1h", "24h", "7d"] as RangeKey[]} /></div>
            {hm ? <HostCharts m={hm} d={d} range={range} /> : <Empty>No history yet. The server samples once a minute once tando-metrics runs (tando host setup).</Empty>}
            <p className="mt-2 mb-0 text-xs text-muted-foreground">Load is the 1-minute average; the dashed line is the number of cores. CPU is the share of all cores. Disk is the filesystem that holds /var/lib/tando. Times are the server's clock, GMT.</p>
          </Section>
          <Section title="Disk">
            <Card>
              <div className="mb-2 flex items-center justify-between text-[13px]"><span>{fmtPct(diskPct)}<span className="text-muted-foreground"> · {fmtBytes(s.disk_used_bytes)} of {fmtBytes(s.disk_total_bytes)}</span></span><span className="text-muted-foreground">full in {DASH}</span></div>
              <Gauge pct={diskPct} label={`Disk ${fmtPct(diskPct)} used`} />
            </Card>
          </Section>
        </>
      )}
      {d && (
        <Section title="Alerts">
          {hostAlerts.length === 0 ? <Empty>No alerts firing.</Empty> : (
            <ul className="m-0 list-none divide-y divide-border overflow-hidden rounded-lg border border-border bg-card p-0">
              {hostAlerts.map((a) => (
                <li key={`${a.app}${a.check}`} className="flex h-9 items-center gap-3 px-3 text-[13px]">
                  <Badge kind={a.state === "firing" ? "fail" : "warn"}>{a.state === "firing" ? "firing" : "pending"}</Badge>
                  <span className="min-w-0 flex-1 truncate">{a.app}<span className="text-muted-foreground"> · {a.check} · {a.detail ?? DASH}</span></span>
                  <span className="shrink-0 text-muted-foreground">{a.since ? `for ${fmtDur(nowS - a.since)}` : DASH}</span>
                </li>
              ))}
            </ul>
          )}
        </Section>
      )}
      <Section title="Doctor" aside={doctor.result && !doctor.error ? <span className="text-xs text-muted-foreground">last run {fmtTime(doctor.result.ran_at ? Date.parse(doctor.result.ran_at) / 1000 : null)}</span> : null}>
        {doctor.error ? <SectionError message={`${doctor.error.message}`} onRetry={doctor.run} />
          : !doctor.result ? <Empty>Not run yet. <Command cmd={`tando doctor ${host}`} /></Empty>
          : (
            <ul className="m-0 list-none divide-y divide-border overflow-hidden rounded-lg border border-border bg-card p-0">
              {(doctor.result.data?.checks ?? []).map((c) => (
                <li key={c.name} className="flex min-h-9 items-center gap-3 px-3 text-[13px]">
                  <Badge kind={c.state === "ok" ? "ok" : c.state === "warn" ? "warn" : "fail"}>{c.state}</Badge>
                  <span className="w-20 shrink-0 font-medium">{c.name}</span><span className="min-w-0 flex-1 truncate text-muted-foreground">{c.detail}</span>
                </li>
              ))}
            </ul>
          )}
      </Section>
      <Section title="Host to-dos" aside={<Button disabled={hs.loading} onClick={hs.run}>{hs.loading ? "Checking…" : hs.result ? "Check again" : "Check host"}</Button>}>
        {hs.error ? <SectionError message={hs.error.message} onRetry={hs.run} />
          : !hs.result ? <Empty>Security updates, reboots and failed units are read on demand. <Command cmd={`tando host status ${host}`} /></Empty>
          : (hs.result.data?.findings ?? []).length === 0 ? <Empty>Nothing to do.</Empty> : (
            <ul className="m-0 list-none divide-y divide-border overflow-hidden rounded-lg border border-border bg-card p-0">
              {(hs.result.data?.findings ?? []).map((f) => (
                <li key={f.id} className="flex min-h-9 items-center gap-3 px-3 text-[13px]">
                  <Badge kind={f.state === "fail" ? "fail" : "warn"}>{f.state}</Badge>
                  <span className="min-w-0 flex-1 truncate">{f.title}{f.detail && <span className="text-muted-foreground"> · {f.detail}</span>}</span>
                  {f.fix && <code className="hidden shrink-0 lg:inline">{f.fix}</code>}
                </li>
              ))}
            </ul>
          )}
      </Section>
      {d && <Section title="Apps"><AppsTable rows={rows} nowS={nowS} alertsByHost={alertsByHost} showServer={false} /></Section>}
    </>
  );
}
