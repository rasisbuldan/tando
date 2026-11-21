// After vite build: the embed needs theme.js as a file of its own (public/ copies it) and no map files.
import { existsSync } from "node:fs";
const out = new URL("../../server/webdist/dist/", import.meta.url);
for (const f of ["index.html", "theme.js", "favicon.svg"]) {
  if (!existsSync(new URL(f, out))) { console.error(`build: ${f} is missing from ${out.pathname}`); process.exit(1); }
}
console.log("build: ok, " + out.pathname);
