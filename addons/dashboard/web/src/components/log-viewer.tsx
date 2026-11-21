// The log viewer (DESIGN 6): filter bar, a virtualised list of fixed-height rows, follow over SSE.
// Lines live in memory only (ring buffer of 5,000); nothing is written to any browser storage.
import { ArrowDown, Pause, Play, RefreshCw } from "lucide-react";
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Button } from "./ui/button";
import { Input, Select, Toggle } from "./ui/select";
import { Empty, SectionError } from "./panel";
import { cn } from "@/lib/cn";
import { apiGet, ApiError } from "@/lib/api";
import { fmtTimeS, fmtTime } from "@/lib/format";
import {
  appendLines, BUFFER_MAX, filterLines, followLine, LEVELS, LogFollow, msgCols, NO_FILTERS, parseLines, rowOffsets,
  streamQuery, tailQuery, textProblem, visibleRange, workersIn, type FollowState, type LogFilters, type LogLine,
} from "@/lib/logs";

const LEVEL_CLASS: Record<string, string> = { err: "text-fail", wrn: "text-warn", inf: "text-muted-foreground", dbg: "text-faint" };

/** sets size and position through the CSSOM (not a style prop: the CSP allows this, DESIGN 12.5) */
function useBox(h: number, y?: number) {
  return useCallback((el: HTMLElement | null) => {
    if (!el) return;
    el.style.height = `${h}px`;
    if (y != null) el.style.transform = `translateY(${y}px)`;
  }, [h, y]);
}

interface Props { host: string; app: string; releases: string[] }

export function LogViewer({ host, app, releases }: Props) {
  const [f, setF] = useState<LogFilters>(NO_FILTERS);
  const [text, setText] = useState("");                // debounced into f.text
  const [follow, setFollow] = useState(false);
  const [wrap, setWrap] = useState(false);
  const [expanded, setExpanded] = useState<ReadonlySet<number>>(new Set());
  const [lines, setLines] = useState<LogLine[]>([]);
  const [fstate, setFstate] = useState<FollowState>({ kind: "idle" });
  const [tail, setTail] = useState<{ loading: boolean; error: ApiError | null; at: number | null; notes: string[] }>({ loading: false, error: null, at: null, notes: [] });
  const [resumeKey, setResumeKey] = useState(0);
  const [pinned, setPinned] = useState(true);
  const [unseen, setUnseen] = useState(0);
  const [size, setSize] = useState({ w: 800, h: 400, top: 0 });
  const box = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const progScroll = useRef(false);
  const pinnedRef = useRef(true);
  pinnedRef.current = pinned;

  // text filter: 250 ms after typing stops
  useEffect(() => { const h = setTimeout(() => setF((x) => (x.text === text ? x : { ...x, text })), 250); return () => clearTimeout(h); }, [text]);
  // `/` focuses the filter (the shell ignores keys typed into a field)
  useEffect(() => {
    const on = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (e.key !== "/" || e.metaKey || e.ctrlKey || e.altKey || (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT"))) return;
      e.preventDefault(); inputRef.current?.focus();
    };
    window.addEventListener("keydown", on);
    return () => window.removeEventListener("keydown", on);
  }, []);

  const problem = textProblem(f.text);
  const canFollow = f.release === "";

  // one-shot tail when not following (and on every filter change)
  useEffect(() => {
    if (follow) return;
    let live = true;
    setTail((t) => ({ ...t, loading: true, error: null }));
    apiGet<{ lines: unknown[]; notes?: string[]; ran_at?: string }>(`/api/logs?${tailQuery(host, app, f)}`)
      .then((r) => { if (!live) return; setLines(appendLines([], parseLines(r.lines ?? []))); setTail({ loading: false, error: null, at: Math.floor(Date.now() / 1000), notes: r.notes ?? [] }); setPinned(true); setUnseen(0); })
      .catch((e: ApiError) => { if (live) setTail((t) => ({ ...t, loading: false, error: e })); });
    return () => { live = false; };
  }, [follow, host, app, f, resumeKey]);

  // follow: one EventSource; closed on `error` and `dropped` by LogFollow, Resume starts a new one
  useEffect(() => {
    if (!follow) { setFstate({ kind: "idle" }); return; }
    setLines([]); setPinned(true); setUnseen(0);
    const fo = new LogFollow(`/api/logs/stream?${streamQuery(host, app, f)}`, (u) => new EventSource(u), {
      onState: setFstate,
      onLines: (b) => { setLines((cur) => appendLines(cur, b)); if (!pinnedRef.current) setUnseen((n) => n + b.length); },
    });
    fo.start();
    return () => fo.stop();
    // the text filter is applied in the page: it does not restart the stream
  }, [follow, host, app, f.level, f.worker, resumeKey]); // eslint-disable-line react-hooks/exhaustive-deps

  const shown = useMemo(() => filterLines(lines, follow ? f.text : ""), [lines, follow, f.text]);
  const hasWorker = useMemo(() => shown.some((l) => l.worker), [shown]);
  const cols = msgCols(size.w, hasWorker);
  const offs = useMemo(() => rowOffsets(shown, wrap, expanded, cols), [shown, wrap, expanded, cols]);
  const total = offs[offs.length - 1];
  const { start, end } = visibleRange(offs, size.top, size.h);

  // measure once, then on resize (ResizeObserver, no layout reads in render)
  useLayoutEffect(() => {
    const el = box.current; if (!el) return;
    const read = () => setSize((s) => (s.w === el.clientWidth && s.h === el.clientHeight ? s : { ...s, w: el.clientWidth, h: el.clientHeight }));
    read();
    const ro = new ResizeObserver(read); ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // follow on: pinned to the bottom after each batch
  useLayoutEffect(() => {
    const el = box.current;
    if (el && pinned && (follow || tail.at)) { progScroll.current = true; el.scrollTop = el.scrollHeight; }
  }, [total, pinned, follow, tail.at]);

  const onScroll = () => {
    const el = box.current; if (!el) return;
    setSize((s) => (s.top === el.scrollTop ? s : { ...s, top: el.scrollTop }));
    if (progScroll.current) { progScroll.current = false; return; }
    const atEnd = el.scrollTop + el.clientHeight >= el.scrollHeight - 4;
    if (atEnd && !pinnedRef.current) { setPinned(true); setUnseen(0); }
    else if (!atEnd && pinnedRef.current) setPinned(false);
  };
  const jump = () => { setPinned(true); setUnseen(0); };

  const workers = useMemo(() => workersIn(lines, f.worker), [lines, f.worker]);
  const toggleRow = (id: number) => setExpanded((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  const stopped = fstate.kind === "stopped";
  const stateLine = follow ? followLine(fstate)
    : tail.error ? "" : tail.loading && !tail.at ? "Reading the last 200 lines…" : `Last ${lines.length === 200 ? "200" : lines.length} lines${tail.at ? `, read ${fmtTime(tail.at)}` : ""}.`;

  return (
    <div className="flex h-[calc(100vh-200px)] min-h-[400px] flex-col gap-2">
      <div role="toolbar" aria-label="Log filters" className="flex min-h-10 flex-wrap items-center gap-2">
        <Select label="Level" value={f.level} onChange={(level) => setF({ ...f, level })} options={[["", "All levels"], ...LEVELS.map((l): [string, string] => [l, l])]} />
        <Input ref={inputRef} aria-label="Filter lines" aria-invalid={!!problem} placeholder="Filter lines (/)" value={text} onChange={(e) => setText(e.target.value)} className="w-56" />
        <Select label="Worker" value={f.worker} onChange={(worker) => setF({ ...f, worker })} options={[["", "All workers"], ...workers.map((w): [string, string] => [w, w])]} />
        <Select label="Release" value={f.release} onChange={(release) => { setF({ ...f, release }); if (release) setFollow(false); }} options={[["", "All releases"], ...releases.map((r): [string, string] => [r, r])]} className="w-44" />
        <span className="ml-auto flex items-center gap-2">
          <Toggle pressed={wrap} onPressedChange={setWrap}>Wrap</Toggle>
          <Toggle pressed={follow} onPressedChange={setFollow} disabled={!canFollow} title={canFollow ? undefined : "A release cannot be followed. Clear the release filter."}>
            {follow ? <Pause size={16} strokeWidth={1.75} aria-hidden="true" /> : <Play size={16} strokeWidth={1.75} aria-hidden="true" />}Follow
          </Toggle>
        </span>
      </div>
      <div className="flex h-6 items-center gap-2 text-xs leading-4 text-muted-foreground" aria-live="polite">
        <span>Logs are not stored.</span><span aria-hidden="true">·</span>
        <span className={cn(stopped && "text-foreground")}>{problem ?? stateLine}</span>
        {stopped && <Button className="h-6 px-2 text-xs" onClick={() => setResumeKey((k) => k + 1)}><Play size={16} strokeWidth={1.75} aria-hidden="true" />Resume</Button>}
        {!follow && !tail.error && <Button variant="ghost" className="h-6 px-2 text-xs" onClick={() => setResumeKey((k) => k + 1)}><RefreshCw size={16} strokeWidth={1.75} aria-hidden="true" />Refresh</Button>}
      </div>
      {tail.error && !follow && <SectionError message={`Could not read the logs: ${tail.error.message}`} onRetry={() => setResumeKey((k) => k + 1)} />}
      <div className="relative min-h-0 flex-1">
        <div ref={box} onScroll={onScroll} role="log" aria-label="Log lines" tabIndex={0}
          className="mono absolute inset-0 overflow-auto rounded-lg border border-border bg-card">
          <div ref={(el) => { if (el) el.style.height = `${total}px`; }} className="relative min-w-full">
            <div ref={(el) => { if (el) el.style.transform = `translateY(${offs[start] ?? 0}px)`; }} className={cn("absolute top-0 left-0", wrap ? "w-full" : "min-w-full")}>
              {shown.slice(start, end).map((l, k) => {
                const i = start + k;
                const open = wrap || expanded.has(l.id);
                return <Row key={l.id} l={l} h={offs[i + 1] - offs[i]} open={open} gutter={hasWorker} onClick={() => toggleRow(l.id)} />;
              })}
            </div>
          </div>
        </div>
        {shown.length === 0 && !tail.loading && !tail.error && (
          <div className="pointer-events-none absolute inset-0 grid place-items-center p-4"><div className="pointer-events-auto"><Empty>{emptyText(f, follow)}</Empty></div></div>
        )}
        {unseen > 0 && !pinned && (
          <Button className="absolute right-4 bottom-4 h-7 shadow-pop" onClick={jump}><ArrowDown size={16} strokeWidth={1.75} aria-hidden="true" />{unseen} new line{unseen === 1 ? "" : "s"} · Jump to latest</Button>
        )}
      </div>
      <p className="m-0 text-xs text-muted-foreground">Times are GMT. {lines.length >= BUFFER_MAX ? `Showing the newest ${BUFFER_MAX} lines. ` : ""}Click a line to wrap it.</p>
    </div>
  );
}

function emptyText(f: LogFilters, follow: boolean): React.ReactNode {
  if (f.text) return <>Nothing matches “{f.text}”. Clear the filter.</>;
  if (f.level || f.worker || f.release) return <>No lines match these filters.</>;
  return follow ? <>Waiting for the first line.</> : <>No log lines yet. They appear when the app writes to stdout or stderr.</>;
}

function Row({ l, h, open, gutter, onClick }: { l: LogLine; h: number; open: boolean; gutter: boolean; onClick: () => void }) {
  const ref = useBox(h);
  return (
    <div ref={ref} role="row" onClick={onClick} className="flex cursor-default gap-2 overflow-hidden px-2 whitespace-nowrap hover:bg-muted/60">
      <span className="w-[8ch] shrink-0 text-muted-foreground">{fmtTimeS(l.t).replace(" GMT", "")}</span>
      <span className={cn("w-[3ch] shrink-0", LEVEL_CLASS[l.level])}>{l.level}</span>
      {gutter && <span className="w-[10ch] shrink-0 truncate text-muted-foreground">{l.worker}</span>}
      <span className={cn("min-w-0 flex-1", open ? "break-all whitespace-pre-wrap" : "truncate")}>{l.msg}</span>
    </div>
  );
}
