// lib/workspace.js: the node_modules of one package of a workspace (a monorepo), as a tree that
// stands on its own (lib/build.sh, stage). The package's dependencies live in the workspace's
// node_modules (npm hoists them to the root, pnpm links them from node_modules/.pnpm, workspace
// packages are symbolic links to their directories); this finds every package the member needs at
// run time, the way Node resolves it, and lays them out in <out>/node_modules. Reads package.json
// files and directories only; never runs anything from them, never uses the network.
//
//   node workspace.js deps <member> <wsroot> <out>
//       <member>: the package's directory, <wsroot>: the workspace root (the lookup stops there),
//       <out>: a directory that is emptied, then filled with node_modules/... (files are hard
//       links to the installed ones where the file system allows, else copies; symbolic links
//       inside a package are kept as they are). Prints one line per package:
//         <dest> <TAB> <name> <TAB> <version> <TAB> workspace|registry
//       Fails (exit 1, the reason on stderr) when a dependency is not installed.
//
// The production dependencies only: dependencies, optionalDependencies and the peerDependencies
// that are installed (an optional one that is missing is left out), as `pnpm deploy --prod` does.
// Layout: each package goes to the top node_modules unless another version of it is there
// already, then into the node_modules of the package that needs it. A package's own node_modules
// is never copied as it is: what is needed from it comes through the same lookup.
"use strict";
const fs = require("fs");
const path = require("path");

const readJSON = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { return null; } };
const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch (e) { return false; } };
const NAME = /^(@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/i;

function deps(member, wsroot, out) {
  member = fs.realpathSync(member);
  wsroot = fs.realpathSync(wsroot);
  const inside = (p) => p === wsroot || p.startsWith(wsroot + path.sep);
  if (!inside(member)) throw new Error(member + " is not inside the workspace " + wsroot);
  // Node's lookup from a package's real directory: <dir>/node_modules/<name>, then each parent's,
  // up to the workspace root (never above it)
  const resolve = (from, name) => {
    for (let d = from; ; d = path.dirname(d)) {
      const p = path.join(d, "node_modules", name);
      if (fs.existsSync(path.join(p, "package.json"))) return fs.realpathSync(p);
      if (d === wsroot || !inside(path.dirname(d))) return null;
    }
  };
  const placed = new Map();   // dest (node_modules/a/node_modules/b) -> real directory
  const parent = (dest) => { const i = dest.lastIndexOf("node_modules/"); return dest.slice(0, i).replace(/\/$/, ""); };
  // the first place a package at dest finds <name>, as Node would in the laid-out tree
  const lookup = (dest, name) => {
    for (let d = dest; ; d = parent(d)) {
      const k = (d ? d + "/" : "") + "node_modules/" + name;
      if (placed.has(k)) return k;
      if (!d) return null;
    }
  };
  const lines = [];
  const queue = [{ src: member, dest: "", json: readJSON(path.join(member, "package.json")) || {} }];
  // (all the direct dependencies of a package are placed before any of theirs: a package placed
  // later never comes between one placed earlier and what it found)
  while (queue.length) {
    const p = queue.shift();
    const want = new Map();
    for (const f of ["dependencies", "optionalDependencies"]) for (const n of Object.keys(p.json[f] || {})) want.set(n, f);
    for (const n of Object.keys(p.json.peerDependencies || {})) if (!want.has(n)) want.set(n, "peer");
    for (const [name, kind] of want) {
      if (!NAME.test(name)) throw new Error("not a package name in " + (p.json.name || "package.json") + ": " + JSON.stringify(name).slice(0, 80));
      const src = resolve(p.src, name);
      if (!src) {
        if (kind !== "dependencies") continue;   // (an optional or peer dependency that is not installed)
        throw new Error(name + " (a dependency of " + (p.json.name || "this package") + ") is not installed in the workspace");
      }
      const found = lookup(p.dest, name);
      if (found && placed.get(found) === src) continue;
      const dest = (found ? (p.dest ? p.dest + "/" : "") : "") + "node_modules/" + name;
      if (placed.has(dest)) throw new Error("two versions of " + name + " for " + (p.json.name || "this package"));
      placed.set(dest, src);
      const json = readJSON(path.join(src, "package.json")) || {};
      lines.push([dest, name, String(json.version || "-"), src.split(path.sep).includes("node_modules") ? "registry" : "workspace"].join("\t"));
      queue.push({ src, dest, json });
    }
  }
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(path.join(out, "node_modules"), { recursive: true });
  for (const [dest, src] of placed) copy(src, path.join(out, dest), true);
  return lines;
}

// copy dir to dest: files hard linked (copied across file systems), symbolic links kept; the
// package's own node_modules (top level) and .git are left out
function copy(src, dest, top) {
  fs.mkdirSync(dest, { recursive: true });
  for (const e of fs.readdirSync(src, { withFileTypes: true })) {
    if (top && (e.name === "node_modules" || e.name === ".git")) continue;
    const s = path.join(src, e.name), d = path.join(dest, e.name);
    if (e.isSymbolicLink()) fs.symlinkSync(fs.readlinkSync(s), d);
    else if (e.isDirectory()) copy(s, d, false);
    else if (e.isFile()) {
      try { fs.linkSync(s, d); } catch (err) { fs.copyFileSync(s, d); }
    }
  }
}

if (require.main === module) {
  const [cmd, ...a] = process.argv.slice(2);
  try {
    if (cmd !== "deps" || a.length !== 3) throw new Error("usage: workspace.js deps <member> <wsroot> <out>");
    process.stdout.write(deps(a[0], a[1], a[2]).map((l) => l + "\n").join(""));
  } catch (e) {
    process.stderr.write(String(e.message || e).replace(/[^\x20-\x7e]/g, "?") + "\n");
    process.exit(1);
  }
}
module.exports = { deps };
