import type { ApiErrorBody } from "./types";

export class ApiError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

// 401 with code `session`: the one full-page state (DESIGN section 7)
let sessionEnded = false;
const subs = new Set<() => void>();
export const sessionStore = {
  get: () => sessionEnded,
  subscribe: (f: () => void) => { subs.add(f); return () => { subs.delete(f); }; },
  end() { if (!sessionEnded) { sessionEnded = true; subs.forEach((f) => f()); } },
  reset() { sessionEnded = false; subs.forEach((f) => f()); },
};

export const REQUEST_TIMEOUT_MS = 15000; // as the CLI's --watch

export interface Fetcher { (url: string, init: { signal: AbortSignal; credentials: "same-origin"; headers: Record<string, string> }): Promise<Pick<Response, "ok" | "status" | "json">> }

export async function apiGet<T>(path: string, fetcher: Fetcher = fetch as Fetcher, timeoutMs = REQUEST_TIMEOUT_MS): Promise<T> {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  let res;
  try {
    res = await fetcher(path, { signal: ctl.signal, credentials: "same-origin", headers: { Accept: "application/json" } });
  } catch {
    throw new ApiError(ctl.signal.aborted ? "timeout" : "network",
      ctl.signal.aborted ? "tando-dash did not answer in 15 s. Retrying." : "Could not reach tando-dash. Check that it is still running.");
  } finally { clearTimeout(timer); }
  let body: unknown = null;
  try { body = await res.json(); } catch { /* not JSON */ }
  if (!res.ok) {
    const e = (body as { error?: ApiErrorBody } | null)?.error;
    if (res.status === 401 && e?.code === "session") { sessionStore.end(); throw new ApiError("session", "Session ended."); }
    throw new ApiError(e?.code ?? `http_${res.status}`, e?.message ?? `tando-dash answered ${res.status}.`);
  }
  if (body == null) throw new ApiError("bad_response", "tando-dash sent something that is not JSON.");
  return body as T;
}

export function qs(p: Record<string, string | undefined>): string {
  const u = new URLSearchParams();
  for (const [k, v] of Object.entries(p)) if (v !== undefined) u.set(k, v);
  return u.toString();
}
