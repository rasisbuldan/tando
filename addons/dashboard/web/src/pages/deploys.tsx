// Deploys (all apps): a timeline of recent deploys across servers with phase bars and results.
import { useMemo, useState } from "react";
import { Link } from "react-router";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Select } from "@/components/ui/select";
import { Table, Td, Th, Tr } from "@/components/ui/table";
import { Tip } from "@/components/ui/tooltip";
import { Mono, Missing, PhaseBar, PhaseLegend } from "@/components/bits";
import { Empty, Freshness, Loading, PageHeader, RefreshButton, Section, SectionError } from "@/components/panel";
import { allHistoryPoller, historyHosts, reachableApps } from "@/lib/extra";
import { overviewPoller, refreshAll, usePoller } from "@/lib/resources";
import { NO_TIMELINE_FILTER, timeline, timelineKey, timelineOptions, type TimelineFilter } from "@/lib/pages";
import { phases, resultKind } from "@/lib/shape";
import { fmtDateTime, fmtSecs, shortId } from "@/lib/format";

const PAGE = 50;
const all = (what: string): [string, string] => ["", what];

export default function DeploysPage() {
  const ov = usePoller(overviewPoller());
  const pairs = useMemo(() => reachableApps(ov.data), [ov.data]);
  const hosts = useMemo(() => historyHosts(ov.data), [ov.data]);
  const st = usePoller(allHistoryPoller(hosts));
  const [f, setF] = useState<TimelineFilter>(NO_TIMELINE_FILTER);
  const [n, setN] = useState(PAGE);
  const rows = st.data?.rows;
  const opts = useMemo(() => timelineOptions(rows ?? []), [rows]);
  const shown = useMemo(() => timeline(rows ?? [], f), [rows, f]);
  const unreachable = (ov.data ?? []).filter((h) => !h.reachable).map((h) => h.host);
  return (
    <>
      <PageHeader title="Deploys" actions={<RefreshButton />} />
      <Freshness st={st.data || st.error ? st : ov} />
      <div className="mt-2 mb-4 flex flex-wrap items-center gap-2">
        <Select label="Server" value={f.host} onChange={(host) => { setF({ ...f, host }); setN(PAGE); }} options={[all("All servers"), ...opts.hosts.map((h): [string, string] => [h, h])]} />
        <Select label="App" value={f.app} onChange={(app) => { setF({ ...f, app }); setN(PAGE); }} options={[all("All apps"), ...opts.apps.map((h): [string, string] => [h, h])]} />
        <Select label="Result" value={f.result} onChange={(result) => { setF({ ...f, result }); setN(PAGE); }} options={[all("All results"), ...opts.results.map((h): [string, string] => [h, h])]} />
      </div>
      <Section title="Timeline">
        {!ov.data && !ov.error && <Loading h="h-64" />}
        {!ov.data && ov.error && <SectionError message={ov.error.message} onRetry={refreshAll} />}
        {ov.data && pairs.length === 0 && <Empty>{unreachable.length ? `${unreachable.join(", ")} not answering. Check ssh access, then retry.` : <>No apps yet. Deploy with <code>tando deploy</code>.</>}</Empty>}
        {pairs.length > 0 && !st.data && !st.error && <Loading h="h-64" />}
        {pairs.length > 0 && !st.data && st.error && <SectionError message={st.error.message} onRetry={refreshAll} />}
        {st.data && (
          <>
            {st.data.failed.length > 0 && <p className="m-0 mb-2 text-xs text-muted-foreground">Could not read the history of {st.data.failed.join(", ")}. Retrying.</p>}
            {unreachable.length > 0 && <p className="m-0 mb-2 text-xs text-muted-foreground">{unreachable.join(", ")} not answering: its deploys are missing.</p>}
            {shown.length === 0 ? (
              (rows ?? []).length === 0 ? <Empty>No deploys yet. Deploy with <code>tando deploy</code>.</Empty>
                : <Empty>Nothing matches these filters. <Button variant="ghost" className="h-6 px-2" onClick={() => setF(NO_TIMELINE_FILTER)}>Clear filters</Button></Empty>
            ) : (
              <>
                <PhaseLegend />
                <div className="overflow-x-auto rounded-lg border border-border bg-card">
                  <Table className="min-w-[1180px]">
                    <thead><tr>
                      <Th className="w-[150px]">Time</Th><Th className="w-[120px]">App</Th><Th className="w-[100px]">Server</Th><Th className="w-[160px]">Kind</Th><Th className="w-[104px]">Result</Th>
                      <Th className="w-[100px]">Deployer</Th><Th className="w-[240px]">Phases</Th><Th>Note</Th>
                    </tr></thead>
                    <tbody>{shown.slice(0, n).map((h) => { const k = resultKind(h.result); return (
                      <Tr key={timelineKey(h)}>
                        <Td>{fmtDateTime(h.at)}</Td>
                        <Td><Link className="hover:underline" to={`/s/${encodeURIComponent(h.host)}/${h.app}/deploys`}>{h.app}</Link></Td>
                        <Td><Mono>{h.host}</Mono></Td>
                        <Td><Tip text={h.release}><span>{h.kind}<span className="text-muted-foreground"> · {shortId(h.release)}</span></span></Tip></Td>
                        <Td><Badge kind={k.kind}>{k.word}</Badge></Td>
                        <Td>{h.deployer ?? <Missing />}</Td>
                        <Td><PhaseBar phases={phases(h)} total={h.total_s} label={phases(h).map((p) => `${p.label} ${fmtSecs(p.s)}`).join(", ") || "no phase times"} /></Td>
                        <Td className="text-muted-foreground">{h.note ? <Tip text={h.note}><span>{h.note}</span></Tip> : <Missing />}</Td>
                      </Tr>); })}</tbody>
                  </Table>
                </div>
                {shown.length > n && <div className="mt-2"><Button onClick={() => setN(n + PAGE)}>Show {PAGE} more</Button></div>}
              </>
            )}
          </>
        )}
      </Section>
    </>
  );
}
