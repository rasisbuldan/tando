/** Keep `prev` objects where nothing changed, so React.memo components skip (rule 4). */
export function share<T>(prev: unknown, next: T): T {
  if (prev === next) return next;
  if (Array.isArray(next) && Array.isArray(prev)) {
    let same = prev.length === next.length;
    const out = next.map((v, i) => { const s = share(prev[i], v); if (s !== prev[i]) same = false; return s; });
    return (same ? prev : out) as T;
  }
  if (next && prev && typeof next === "object" && typeof prev === "object" && !Array.isArray(prev)) {
    const n = next as Record<string, unknown>, p = prev as Record<string, unknown>;
    const nk = Object.keys(n);
    let same = nk.length === Object.keys(p).length;
    const out: Record<string, unknown> = {};
    for (const k of nk) { out[k] = share(p[k], n[k]); if (out[k] !== p[k]) same = false; }
    return (same ? prev : out) as T;
  }
  return next;
}
