import { Link } from "react-router";
import { HostCard } from "@/components/host-card";
import { AppsTable } from "@/components/apps-table";
import { Badge } from "@/components/ui/badge";
import { Empty, Freshness, Loading, PageHeader, RefreshButton, Section, SectionError } from "@/components/panel";
import { overviewPoller, useNowMs, usePoller, refreshAll } from "@/lib/resources";
import { appRows, needsAttention } from "@/lib/shape";
import { fmtFor } from "@/lib/format";
import { useMemo } from "react";

export default function Overview() {
  const p = overviewPoller();
  const st = usePoller(p);
  const nowS = Math.floor(useNowMs(30000) / 1000);
  const hosts = st.data;
  const attention = useMemo(() => (hosts ? needsAttention(hosts) : []), [hosts]);
  const rows = useMemo(() => (hosts ? appRows(hosts) : []), [hosts]);
  const alertsByHost = useMemo(() => Object.fromEntries((hosts ?? []).map((h) => [h.host, h.data?.alerts])), [hosts]);

  return (
    <>
      <PageHeader title="Overview" actions={<RefreshButton />} />
      <Freshness st={st} />
      {!hosts && st.error && <SectionError message={`${st.error.message}`} onRetry={refreshAll} />}
      {!hosts && !st.error && <Loading h="h-96" />}
      {hosts && (
        <>
          {attention.length > 0 && (
            <Section title="Needs attention">
              <ul className="m-0 list-none divide-y divide-border overflow-hidden rounded-lg border border-border bg-card p-0">
                {attention.map((a) => (
                  <li key={a.key} className="flex h-9 items-center gap-3 px-3 text-[13px]">
                    <Badge kind={a.kind}>{a.word}</Badge>
                    <span className="min-w-0 flex-1 truncate">
                      <Link to={a.app ? `/s/${a.host}/${a.app}` : `/s/${a.host}`} className="inset-focus font-medium hover:underline">{a.app ?? a.host}</Link>
                      <span className="text-muted-foreground"> · {a.app ? `${a.host} · ` : ""}{a.what}</span>
                    </span>
                    <span className="shrink-0 text-muted-foreground">{fmtFor(nowS, a.since)}</span>
                  </li>
                ))}
              </ul>
            </Section>
          )}
          <Section title="Servers">
            {hosts.length === 0
              ? <Empty>No servers yet. Add one with <code>tando host add</code>.</Empty>
              : <div className="grid grid-cols-1 gap-3 min-[641px]:grid-cols-2 min-[1280px]:grid-cols-3">{hosts.map((h) => <HostCard key={h.host} h={h} />)}</div>}
          </Section>
          <Section title="Apps">
            <AppsTable rows={rows} nowS={nowS} alertsByHost={alertsByHost} />
          </Section>
        </>
      )}
    </>
  );
}
