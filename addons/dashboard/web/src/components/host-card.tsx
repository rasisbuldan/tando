import { memo } from "react";
import { Link } from "react-router";
import { RefreshCw } from "lucide-react";
import { Badge } from "./ui/badge";
import { Button } from "./ui/button";
import { Card } from "./ui/card";
import { Mono, SshTarget } from "./bits";
import { fmtBytes, fmtLoad, fmtPct, fmtTime, pctOf } from "@/lib/format";
import { headroom, skewNote, sshTarget } from "@/lib/shape";
import type { HostView } from "@/lib/types";
import { refreshAll } from "@/lib/resources";

/** one server: reachable, load, memory, disk, headroom; failure says what and what to do, data stays */
export const HostCard = memo(function HostCard({ h }: { h: HostView }) {
  const d = h.data, s = d?.system;
  const hr = headroom(d?.apps, s?.memory_total_bytes);
  const skew = skewNote(d?.clock_skew_s);
  const diskPct = pctOf(s?.disk_used_bytes, s?.disk_total_bytes);
  return (
    <Card className="min-h-[148px]">
      <div className="mb-2 flex items-center justify-between gap-2">
        <span className="flex min-w-0 items-center gap-2">
          <Link to={`/s/${encodeURIComponent(h.host)}`} className="inset-focus shrink-0"><Mono className="text-[15px] font-semibold">{h.host}</Mono></Link>
          <SshTarget target={sshTarget(d)} />
        </span>
        {h.reachable ? <Badge kind="ok">reachable</Badge> : <Badge kind="fail">not answering</Badge>}
      </div>
      {!h.reachable && (
        <div className="mb-2 flex items-center justify-between gap-2 text-[13px]">
          <span>{h.error ? `${h.error}.` : ""} Check ssh access, then retry.</span>
          <Button onClick={refreshAll}><RefreshCw size={16} strokeWidth={1.75} aria-hidden="true" />Retry</Button>
        </div>
      )}
      {s ? (
        <dl className="m-0 grid grid-cols-[88px_1fr] gap-x-2 gap-y-0.5 text-[13px] leading-5">
          <dt className="text-muted-foreground">Load</dt><dd className="m-0">{fmtLoad(s.load_1)} · {fmtLoad(s.load_5)} · {fmtLoad(s.load_15)}<span className="text-muted-foreground"> · {s.cpus ?? "—"} cpu</span></dd>
          <dt className="text-muted-foreground">Memory</dt><dd className="m-0">{fmtBytes(s.memory_used_bytes)} of {fmtBytes(s.memory_total_bytes)}<span className="text-muted-foreground"> · {fmtPct(pctOf(s.memory_used_bytes, s.memory_total_bytes))}</span></dd>
          <dt className="text-muted-foreground">Disk</dt><dd className="m-0">{fmtPct(diskPct)}<span className="text-muted-foreground"> · {fmtBytes(s.disk_used_bytes)} of {fmtBytes(s.disk_total_bytes)}</span></dd>
          <dt className="text-muted-foreground">Headroom</dt><dd className="m-0">{hr ? <>caps {fmtBytes(hr.capBytes)} of {fmtBytes(hr.ramBytes)} RAM<span className="text-muted-foreground"> · {fmtPct(hr.pct)}</span></> : <span className="text-faint">—</span>}</dd>
        </dl>
      ) : null}
      <div className="mt-2 flex items-center justify-between gap-2 text-xs leading-4 text-muted-foreground">
        <span className="min-w-0 truncate">{d ? <>tando {d.server_version ?? "—"}{skew ? ` · ${skew}` : ""}{!h.reachable && h.fetchedAtS ? ` · data from ${fmtTime(h.fetchedAtS)}` : ""}</> : null}</span>
        {s ? <Link to={`/s/${encodeURIComponent(h.host)}`} className="inset-focus shrink-0 underline-offset-2 hover:underline">History</Link> : null}
      </div>
    </Card>
  );
});
