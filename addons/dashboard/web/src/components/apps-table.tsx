import { memo, useEffect, useMemo, useState } from "react";
import { Link } from "react-router";
import { ArrowDown, ArrowUp } from "lucide-react";
import { Badge } from "./ui/badge";
import { Table, Td, Th, Tr } from "./ui/table";
import { Tip } from "./ui/tooltip";
import { Age, Cell, Mono, Missing } from "./bits";
import { Empty } from "./panel";
import { Button } from "./ui/button";
import { appKind, keepOrder, nextSort, rowKey, sortRows, stateWithReason, type AppTableRow, type Sort, type SortKey } from "@/lib/shape";
import { fmtBytes, fmtBytesNum, fmtDateTime, fmtDur, fmtPct, shortId } from "@/lib/format";
import type { Alert } from "@/lib/types";

interface Col { key: SortKey; label: string; w: string; right?: boolean }
const COLS: Col[] = [
  { key: "state", label: "State", w: "w-[168px]" }, { key: "app", label: "App", w: "w-[120px]" }, { key: "host", label: "Server", w: "w-[110px]" },
  { key: "release", label: "Release", w: "w-[200px]" }, { key: "memory", label: "Memory", w: "w-[150px]", right: true },
  { key: "cpu", label: "CPU", w: "w-[72px]", right: true }, { key: "restarts", label: "Restarts", w: "w-[88px]", right: true },
  { key: "uptime", label: "Uptime", w: "w-[96px]", right: true }, { key: "deployed", label: "Last deploy", w: "w-[150px]" },
  { key: "alerts", label: "Alerts", w: "w-[72px]", right: true },
];

const Row = memo(function Row({ r, nowS, alerts, showServer }: { r: AppTableRow; nowS: number; alerts: Alert[] | undefined; showServer: boolean }) {
  const k = r.stale ? { kind: "stale" as const, word: "stale" } : appKind(r);
  const label = r.stale ? `${appKind(r).word} (stale)` : stateWithReason(r, alerts);
  const mem = r.memory_bytes && r.memory_bytes > 0 ? r.memory_bytes : null;
  return (
    <Tr>
      <Td><Badge kind={k.kind}>{label}</Badge></Td>
      <Td><Tip text={r.app}><Link to={`/s/${encodeURIComponent(r.host)}/${r.app}`} className="inset-focus font-medium underline-offset-2 hover:underline">{r.app}</Link></Tip></Td>
      {showServer && <Td><Mono>{r.host}</Mono></Td>}
      <Td>{r.release ? <Tip text={r.release}><span><Mono>{shortId(r.release)}</Mono>{r.deployed_at != null && <span className="text-muted-foreground"> · <Age t={r.deployed_at} nowS={nowS} /></span>}</span></Tip> : <Missing />}</Td>
      <Td className="text-right">{mem ? <Cell sub={r.memory_max_bytes ? `of ${fmtBytesNum(r.memory_max_bytes, r.memory_max_bytes)}` : undefined}>{fmtBytes(mem)}</Cell> : <Missing />}</Td>
      <Td className="text-right">{r.cpu_percent != null ? fmtPct(r.cpu_percent) : <Missing />}</Td>
      <Td className="text-right">{r.restarts ?? <Missing />}</Td>
      <Td className="text-right">{r.uptime_s ? fmtDur(r.uptime_s) : <Missing />}</Td>
      <Td>{r.deployed_at != null ? fmtDateTime(r.deployed_at) : <Missing />}</Td>
      <Td className="text-right">{r.alerts_firing ? <span className="text-fail">{r.alerts_firing}</span> : <Missing />}</Td>
    </Tr>
  );
});

/** Sortable apps table. Rows keep their place on polls: the order is computed on mount, on a
 *  user sort and on a refresh (r / Refresh), never on a poll. */
export function AppsTable({ rows, nowS, alertsByHost, showServer = true, skeletonRows = 8 }: {
  rows: AppTableRow[]; nowS: number; alertsByHost: Record<string, Alert[] | undefined>; showServer?: boolean; skeletonRows?: number;
}) {
  const [sort, setSort] = useState<Sort | null>(null);
  const [order, setOrder] = useState<string[]>(() => sortRows(rows, null).map(rowKey));
  const [seen, setSeen] = useState(rows.length > 0);
  useEffect(() => { // the first data after an empty start sets the order
    if (!seen && rows.length) { setOrder(sortRows(rows, sort).map(rowKey)); setSeen(true); }
  }, [rows, seen, sort]);
  useEffect(() => {
    const f = () => setOrder(sortRowsRef(rows, sort));
    window.addEventListener("tando:refresh", f);
    return () => window.removeEventListener("tando:refresh", f);
  }, [rows, sort]);
  const click = (key: SortKey) => { const s = nextSort(sort, key); setSort(s); setOrder(sortRows(rows, s).map(rowKey)); };
  const shown = useMemo(() => keepOrder(order, rows), [order, rows]);
  const cols = showServer ? COLS : COLS.filter((c) => c.key !== "host");
  void skeletonRows;

  if (rows.length === 0) return <Empty>No apps yet. Deploy with <code>tando deploy</code>.</Empty>;
  return (
    <div className="overflow-x-auto rounded-lg border border-border bg-card">
      <Table className={showServer ? "min-w-[1300px]" : "min-w-[1190px]"}>
        <thead>
          <tr>
            {cols.map((c) => (
              <Th key={c.key} className={`${c.w} ${c.right ? "text-right" : ""}`} aria-sort={sort?.key === c.key ? (sort.dir === "asc" ? "ascending" : "descending") : undefined}>
                <Button variant="ghost" className={`inset-focus h-8 w-full justify-start px-0 text-xs font-medium text-muted-foreground ${c.right ? "justify-end" : ""}`} onClick={() => click(c.key)}>
                  {c.label}
                  {sort?.key === c.key && (sort.dir === "asc" ? <ArrowUp size={12} strokeWidth={1.75} aria-hidden="true" /> : <ArrowDown size={12} strokeWidth={1.75} aria-hidden="true" />)}
                </Button>
              </Th>
            ))}
          </tr>
        </thead>
        <tbody>{shown.map((r) => <Row key={rowKey(r)} r={r} nowS={nowS} alerts={alertsByHost[r.host]} showServer={showServer} />)}</tbody>
      </Table>
    </div>
  );
}
const sortRowsRef = (rows: AppTableRow[], s: Sort | null) => sortRows(rows, s).map(rowKey);
