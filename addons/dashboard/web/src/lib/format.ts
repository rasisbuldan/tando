// Units, GMT times and copy per docs/DESIGN.md section 9. One cached formatter each (rule 11).
export const DASH = "—";
const KB = 1024;

export function fmtBytes(n: number | null | undefined): string {
  if (n == null) return DASH;
  const mb = n / (KB * KB);
  if (mb < KB) return `${Math.round(mb)} MB`;
  return `${(mb / KB).toFixed(1)} GB`;
}
/** bytes in the unit of `ref` ("412 MB · of 512"): number only */
export function fmtBytesNum(n: number, ref: number): string {
  const mb = n / (KB * KB);
  return ref / (KB * KB) < KB ? String(Math.round(mb)) : (mb / KB).toFixed(1);
}
export function fmtPct(p: number | null | undefined): string {
  if (p == null) return DASH;
  return p < 10 ? `${(Math.round(p * 10) / 10).toString()}%` : `${Math.round(p)}%`;
}
export function pctOf(a: number | null | undefined, b: number | null | undefined): number | null {
  if (a == null || !b) return null;
  return (a / b) * 100;
}
export function fmtMs(n: number | null | undefined): string { return n == null ? DASH : `${Math.round(n)} ms`; }
export function fmtLoad(n: number | null | undefined): string { return n == null ? DASH : n.toFixed(2); }

export function fmtDur(s: number | null | undefined): string {
  if (s == null) return DASH;
  s = Math.max(0, Math.round(s));
  if (s < 60) return `${s} s`;
  if (s < 3600) { const m = Math.floor(s / 60), r = s % 60; return r ? `${m} min ${r} s` : `${m} min`; }
  if (s < 86400) { const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60); return m ? `${h} h ${m} min` : `${h} h`; }
  return `${Math.floor(s / 86400)} d`;
}
/** build/upload phase times: sub-second values keep one decimal */
export function fmtSecs(s: number | null | undefined): string {
  if (s == null) return DASH;
  return s < 10 && s % 1 !== 0 ? `${s.toFixed(1)} s` : fmtDur(s);
}

const hm = new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
const hms = new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" });
const dm = new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", day: "numeric", month: "short" });

export function fmtTime(t: number | null | undefined): string { return t == null ? DASH : `${hm.format(t * 1000)} GMT`; }
export function fmtTimeS(t: number): string { return `${hms.format(t * 1000)} GMT`; }
export function fmtDateTime(t: number | null | undefined): string { return t == null ? DASH : `${dm.format(t * 1000)} ${hm.format(t * 1000)} GMT`; }
export function fmtDate(t: number): string { return dm.format(t * 1000); }

export function fmtAgo(nowS: number, t: number | null | undefined): string {
  if (t == null) return DASH;
  const d = nowS - t;
  if (d < 5) return "just now";
  if (d < 60) return `${Math.floor(d)} s ago`;
  if (d < 3600) return `${Math.floor(d / 60)} min ago`;
  if (d < 86400) return `${Math.floor(d / 3600)} h ago`;
  return `${Math.floor(d / 86400)} d ago`;
}
export function fmtFor(nowS: number, since: number | null | undefined): string {
  if (since == null) return DASH;
  return `for ${fmtDur(nowS - since)}`;
}
/** "20261121-140233" -> "2026…140233" when the column is narrow */
export function shortId(id: string | null | undefined): string {
  if (!id) return DASH;
  return id.length > 12 ? `${id.slice(0, 4)}…${id.slice(-6)}` : id;
}
