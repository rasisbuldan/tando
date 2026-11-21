export type Theme = "system" | "light" | "dark";
const KEY = "tando-theme"; // the key /theme.js reads before first paint
export function getTheme(): Theme {
  try { const t = localStorage.getItem(KEY); if (t === "light" || t === "dark") return t; } catch { /* private mode */ }
  return "system";
}
export function applyTheme(t: Theme) {
  try { if (t === "system") localStorage.removeItem(KEY); else localStorage.setItem(KEY, t); } catch { /* ignore */ }
  const dark = t === "dark" || (t === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.classList.toggle("dark", dark);
}
export function lsGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
export function lsSet(k: string, v: string) { try { localStorage.setItem(k, v); } catch { /* ignore */ } }
