import { useState } from "react";
import { Badge, Tag } from "./ui/badge";
import { Button } from "./ui/button";
import { Table, Td, Th, Tr } from "./ui/table";
import { Tip } from "./ui/tooltip";
import { Empty } from "./panel";
import { Mono, Missing, PhaseBar, PhaseLegend } from "./bits";
import { phases, resultKind, rollbackTarget } from "@/lib/shape";
import { fmtDateTime, fmtSecs, shortId } from "@/lib/format";
import type { HistoryRow, Release } from "@/lib/types";

const PAGE = 50;
export function HistoryTable({ rows }: { rows: HistoryRow[] }) {
  const [n, setN] = useState(PAGE);
  if (rows.length === 0) return <Empty>No deploys yet. Deploy with <code>tando deploy</code>.</Empty>;
  const sorted = [...rows].sort((a, b) => b.at - a.at);
  return (
    <>
      <PhaseLegend />
      <div className="overflow-x-auto rounded-lg border border-border bg-card">
        <Table className="min-w-[1000px]">
          <thead><tr>
            <Th className="w-[150px]">Time</Th><Th className="w-[130px]">Release</Th><Th className="w-[84px]">Kind</Th><Th className="w-[104px]">Result</Th>
            <Th className="w-[110px]">Deployer</Th><Th className="w-[240px]">Phases</Th><Th>Note</Th>
          </tr></thead>
          <tbody>
            {sorted.slice(0, n).map((h) => {
              const k = resultKind(h.result);
              return (
                <Tr key={`${h.at}-${h.release}-${h.kind}`}>
                  <Td>{fmtDateTime(h.at)}</Td>
                  <Td><Tip text={h.release}><Mono>{shortId(h.release)}</Mono></Tip></Td>
                  <Td>{h.kind}</Td>
                  <Td><Badge kind={k.kind}>{k.word}</Badge></Td>
                  <Td>{h.deployer ?? <Missing />}</Td>
                  <Td><PhaseBar phases={phases(h)} total={h.total_s} label={phases(h).map((p) => `${p.label} ${fmtSecs(p.s)}`).join(", ") || "no phase times"} /></Td>
                  <Td className="text-muted-foreground">{h.note ? <Tip text={h.note}><span>{h.note}</span></Tip> : <Missing />}</Td>
                </Tr>
              );
            })}
          </tbody>
        </Table>
      </div>
      {sorted.length > n && <div className="mt-2"><Button onClick={() => setN(n + PAGE)}>Show {PAGE} more</Button></div>}
    </>
  );
}

/** releases: live and rollback target tagged; no action buttons until M4 */
export function ReleasesTable({ rows }: { rows: Release[] }) {
  if (rows.length === 0) return <Empty>No releases yet. Deploy with <code>tando deploy</code>.</Empty>;
  const target = rollbackTarget(rows);
  return (
    <div className="overflow-x-auto rounded-lg border border-border bg-card">
      <Table className="min-w-[560px]">
        <thead><tr><Th className="w-[180px]">Release</Th><Th className="w-[170px]">Deployed</Th><Th className="w-[120px]">Status</Th><Th>Tags</Th></tr></thead>
        <tbody>
          {rows.map((r) => {
            const k = resultKind(r.status);
            return (
              <Tr key={r.id}>
                <Td><Mono>{r.id}</Mono></Td>
                <Td>{fmtDateTime(r.deployed_at)}</Td>
                <Td><Badge kind={k.kind}>{k.word}</Badge></Td>
                <Td><span className="inline-flex gap-2">{r.current && <Tag>live</Tag>}{r.id === target && <Tag>rollback target</Tag>}</span></Td>
              </Tr>
            );
          })}
        </tbody>
      </Table>
    </div>
  );
}
