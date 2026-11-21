// Alerts: firing and pending across servers, the last 7 days, and where notifications go.
import { useMemo } from "react";
import { Link } from "react-router";
import { Badge } from "@/components/ui/badge";
import { Table, Td, Th, Tr } from "@/components/ui/table";
import { Tip } from "@/components/ui/tooltip";
import { Age, Missing, Mono } from "@/components/bits";
import { Empty, Freshness, Loading, PageHeader, RefreshButton, Section, SectionError } from "@/components/panel";
import { ExtraBody } from "@/components/extra-body";
import { allAlertsPoller } from "@/lib/extra";
import { overviewPoller, refreshAll, useNowMs, usePoller } from "@/lib/resources";
import { alertRows, alertSpans, type AlertRow } from "@/lib/pages";
import { DASH, fmtDateTime, fmtDur, fmtFor } from "@/lib/format";

function AlertTable({ rows, nowS, empty }: { rows: AlertRow[]; nowS: number; empty: string }) {
  if (rows.length === 0) return <Empty>{empty}</Empty>;
  return (
    <div className="overflow-x-auto rounded-lg border border-border bg-card">
      <Table className="min-w-[760px]">
        <thead><tr><Th className="w-[104px]">State</Th><Th className="w-[130px]">App</Th><Th className="w-[100px]">Server</Th><Th className="w-[110px]">Check</Th><Th>Detail</Th><Th className="w-[130px]">Since</Th></tr></thead>
        <tbody>{rows.map((a) => (
          <Tr key={`${a.host}/${a.app}/${a.check}`}>
            <Td><Badge kind={a.state === "firing" ? "fail" : "warn"}>{a.state === "firing" ? "firing" : "pending"}</Badge>{a.silenced && <span className="ml-1"><Badge kind="info" dot={false}>silenced</Badge></span>}</Td>
            <Td>{a.app === "host" ? <span className="text-muted-foreground">host</span> : <Link className="hover:underline" to={`/s/${encodeURIComponent(a.host)}/${a.app}`}>{a.app}</Link>}</Td>
            <Td><Link className="mono hover:underline" to={`/s/${encodeURIComponent(a.host)}`}>{a.host}</Link></Td>
            <Td>{a.check ?? DASH}</Td>
            <Td className="text-muted-foreground">{a.detail ? <Tip text={a.detail}><span>{a.detail}</span></Tip> : <Missing />}</Td>
            <Td>{a.since != null ? <Tip text={fmtDateTime(a.since)}><span>{fmtFor(nowS, a.since)}</span></Tip> : <Missing />}</Td>
          </Tr>))}</tbody>
      </Table>
    </div>
  );
}

export default function AlertsPage() {
  const ov = usePoller(overviewPoller());
  const nowS = Math.floor(useNowMs(30000) / 1000);
  const hosts = useMemo(() => (ov.data ?? []).filter((h) => h.reachable).map((h) => h.host), [ov.data]);
  const ext = usePoller(allAlertsPoller(hosts));
  const { firing, pending } = useMemo(() => alertRows((ov.data ?? []).map((h) => ({ host: h.host, alerts: h.data?.alerts }))), [ov.data]);
  const spans = useMemo(() => alertSpans((ext.data?.byHost ?? []).flatMap((h) => h.history.map((e) => ({ ...e, host: h.host }))), nowS), [ext.data, nowS]);
  const notifiers = (ext.data?.byHost ?? []).flatMap((h) => h.notifiers.map((n) => ({ ...n, host: h.host })));
  const unreachable = (ov.data ?? []).filter((h) => !h.reachable).map((h) => h.host);
  const head = !ov.data && ov.error ? <SectionError message={ov.error.message} onRetry={refreshAll} /> : !ov.data ? <Loading h="h-24" /> : null;
  return (
    <>
      <PageHeader title="Alerts" actions={<RefreshButton />} />
      <Freshness st={ov} />
      {unreachable.length > 0 && <p className="m-0 mb-2 text-xs text-muted-foreground">{unreachable.join(", ")} not answering: its alerts are missing. Check ssh access, then retry.</p>}
      <Section title="Firing">{head ?? <AlertTable rows={firing} nowS={nowS} empty="No alerts firing." />}</Section>
      <Section title="Pending">{head ?? <AlertTable rows={pending} nowS={nowS} empty="No alerts pending." />}</Section>
      <Section title="History" aside={<span className="text-xs text-muted-foreground">last 7 days</span>}>
        {hosts.length === 0 ? (ov.data ? <Empty>No reachable server to read the history from.</Empty> : <Loading h="h-24" />) : (
          <ExtraBody st={ext} what="alert history">{(d) => (
            <>
              {d.failed.length > 0 && <p className="m-0 mb-2 text-xs text-muted-foreground">Could not read {d.failed.map((x) => x.host).join(", ")}: {d.failed[0].message}</p>}
              {spans.length === 0 ? <Empty>No alerts in the last 7 days.</Empty> : (
                <div className="overflow-x-auto rounded-lg border border-border bg-card">
                  <Table className="min-w-[760px]">
                    <thead><tr><Th className="w-[110px]">Check</Th><Th className="w-[130px]">App</Th><Th className="w-[100px]">Server</Th><Th className="w-[150px]">From</Th><Th className="w-[150px]">To</Th><Th className="w-[110px]">Lasted</Th><Th>Detail</Th></tr></thead>
                    <tbody>{spans.map((s) => (
                      <Tr key={`${s.host}/${s.app}/${s.check}/${s.from ?? s.to}`}>
                        <Td>{s.check}</Td><Td>{s.app === "host" ? <span className="text-muted-foreground">host</span> : s.app}</Td><Td><Mono>{s.host}</Mono></Td>
                        <Td>{fmtDateTime(s.from)}</Td><Td>{s.to != null ? fmtDateTime(s.to) : <Badge kind="fail">ongoing</Badge>}</Td>
                        <Td>{s.durationS != null ? fmtDur(s.durationS) : s.to == null && s.from != null ? fmtDur(nowS - s.from) : DASH}</Td>
                        <Td className="text-muted-foreground">{s.detail ? <Tip text={s.detail}><span>{s.detail}</span></Tip> : <Missing />}</Td>
                      </Tr>))}</tbody>
                  </Table>
                </div>
              )}
            </>
          )}</ExtraBody>
        )}
      </Section>
      <Section title="Notifications" aside={<span className="text-xs text-muted-foreground">where alerts go</span>}>
        {hosts.length === 0 ? <Empty>No reachable server to read the notifiers from.</Empty> : (
          <ExtraBody st={ext} what="notifiers">{() => notifiers.length === 0 ? <Empty>No notifier set up. Alerts show here only. Add one with <code>tando alerts notifier add</code>.</Empty> : (
            <div className="overflow-x-auto rounded-lg border border-border bg-card">
              <Table className="min-w-[760px]">
                <thead><tr><Th className="w-[140px]">Name</Th><Th className="w-[90px]">Kind</Th><Th className="w-[100px]">Server</Th><Th className="w-[110px]">Status</Th><Th className="w-[130px]">Last delivered</Th><Th className="w-[80px] text-right">Queued</Th><Th>Error</Th></tr></thead>
                <tbody>{notifiers.map((n) => (
                  <Tr key={`${n.host}/${n.name}`}>
                    <Td><Mono>{n.name}</Mono></Td><Td>{n.type ?? DASH}</Td><Td><Mono>{n.host}</Mono></Td>
                    <Td><Badge kind={n.error || (n.failures ?? 0) > 0 ? "fail" : "ok"}>{n.error || (n.failures ?? 0) > 0 ? "failing" : "ok"}</Badge></Td>
                    <Td><Age t={n.last_ok} nowS={nowS} /></Td><Td className="text-right">{n.queued ?? DASH}</Td>
                    <Td className="text-muted-foreground">{n.error ? <Tip text={n.error}><span>{n.error}</span></Tip> : <Missing />}</Td>
                  </Tr>))}</tbody>
              </Table>
            </div>
          )}</ExtraBody>
        )}
      </Section>
    </>
  );
}
