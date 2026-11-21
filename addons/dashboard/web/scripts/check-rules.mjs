// DESIGN.md rules that are cheap to grep: no colour literals outside tokens.css, no style prop or
// <style> in our code, at most 24 lucide icons, only allowed dependencies.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const src = new URL("../src/", import.meta.url).pathname;
const files = [];
(function walk(d) { for (const f of readdirSync(d)) { const p = join(d, f); statSync(p).isDirectory() ? walk(p) : files.push(p); } })(src);
const fails = [];
const check = (ok, msg) => { if (!ok) fails.push(msg); console.log(`${ok ? "ok  " : "FAIL"} ${msg}`); };

const lit = /#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|oklch|oklab)\(/;
const code = files.filter((f) => /\.(tsx?|css)$/.test(f) && !f.endsWith("tokens.css") && !/\.test\.ts$/.test(f));
const bad = code.filter((f) => lit.test(readFileSync(f, "utf8").replace(/\/\*[\s\S]*?\*\//g, "")));
check(bad.length === 0, `no colour literal outside tokens.css${bad.length ? ": " + bad.join(", ") : ""}`);

const tsx = files.filter((f) => f.endsWith(".tsx"));
const styled = tsx.filter((f) => /\sstyle=\{|<style[\s>]/.test(readFileSync(f, "utf8")));
check(styled.length === 0, `no style prop and no <style> in our code${styled.length ? ": " + styled.join(", ") : ""}`);

const icons = new Set();
for (const f of tsx) for (const m of readFileSync(f, "utf8").matchAll(/import\s*\{([^}]+)\}\s*from\s*"lucide-react"/g)) m[1].split(",").map((s) => s.trim()).filter(Boolean).forEach((i) => icons.add(i));
check(icons.size <= 24, `${icons.size} distinct lucide icons (<= 24)`);

const allowed = /^(react|react-dom|react-router|@tanstack\/react-query|@tanstack\/react-table|@tanstack\/react-virtual|recharts|@radix-ui\/.+|sonner|lucide-react|clsx|tailwind-merge)$/;
const deps = Object.keys(JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).dependencies ?? {});
const extra = deps.filter((d) => !allowed.test(d));
check(extra.length === 0, `only allowed runtime dependencies${extra.length ? ": " + extra.join(", ") : ""}`);

if (fails.length) { console.error(`\n${fails.length} rule check(s) failed`); process.exit(1); }
