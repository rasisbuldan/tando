// lib/native.js: the planning half of swap_native (lib/build.sh). Reads JSON only (package.json
// files of the staged tree, the project's lockfile); never runs anything from them. Node.js is
// there whenever this runs: it is what built the node_modules being swapped, and npm needs it.
//
//   node native.js plan <stage> <cpu> <libc> <lockdir>
//       every npm package in <stage> (any depth of node_modules) whose package.json says it is
//       for another os/cpu/libc than linux-<cpu>-<libc>, and what replaces it. One line each:
//         swap <TAB> from <TAB> dest <TAB> name <TAB> version <TAB> integrity|- <TAB> lock
//         fail <TAB> message
//       lock: found:<file> (integrity is the lockfile's sha512 for name@version), absent:<file>
//       (the lockfile has no sha512 for it), none (no lockfile), unsupported:<file>
//   node native.js hash <file>            the file's sha512, as an SRI string (sha512-<base64>)
//   node native.js check <dir> <name> <version>   the unpacked package is what was asked for
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const NAME = /^(@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/;
const EXACT = /^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$/;
const validName = (n) => typeof n === "string" && n.length <= 214 && NAME.test(n);
const exact = (v) => typeof v === "string" && v.length <= 64 && EXACT.test(v);
// what reaches the terminal from a package.json: printable ASCII, short
const show = (s) => JSON.stringify(String(s).replace(/[^\x20-\x7e]/g, "?").slice(0, 60));
// the platform part of a package name: <prefix><os>-<cpu>[-<abi>] (sharp-darwin-arm64,
// swc-linux-x64-gnu, @esbuild/darwin-arm64, rollup-win32-x64-msvc, sharp-linuxmusl-x64)
const PLAT = /^(.*?)(darwin|linux|linuxmusl|win32|freebsd|openbsd|netbsd|android|sunos|aix)-(x64|arm64|arm|ia32|ppc64|s390x|riscv64|loong64|mips64el|universal)(-(gnu|musl|msvc|gnueabihf|musleabihf|eabi))?$/;

function readJSON(f) {
  try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { return null; }
}
const isDir = (p) => { try { return fs.lstatSync(p).isDirectory(); } catch (e) { return false; } };
const list = (d) => { try { return fs.readdirSync(d).sort(); } catch (e) { return []; } };

// every package directory under <root>/node_modules, at any depth (a package's own node_modules
// holds the next level); symbolic links and dot entries (.bin, .pnpm) are not followed
function packages(root, rel, out) {
  const nm = rel ? rel + "/node_modules" : "node_modules";
  for (const e of list(path.join(root, nm))) {
    if (e.startsWith(".")) continue;
    const dirs = [];
    if (e.startsWith("@")) {
      if (!isDir(path.join(root, nm, e))) continue;
      for (const s of list(path.join(root, nm, e))) if (!s.startsWith(".")) dirs.push(nm + "/" + e + "/" + s);
    } else dirs.push(nm + "/" + e);
    for (const d of dirs) {
      if (!isDir(path.join(root, d))) continue;
      out.push(d);
      if (isDir(path.join(root, d, "node_modules"))) packages(root, d, out);
    }
  }
  return out;
}

// the package's name from its place: the part after the last node_modules/
function nameOf(rel) {
  const p = rel.split("/");
  return p[p.length - 2].startsWith("@") ? p[p.length - 2] + "/" + p[p.length - 1] : p[p.length - 1];
}

function fits(field, want) {   // an os/cpu/libc list of package.json (["!win32"] style too)
  if (field === undefined) return true;
  const l = Array.isArray(field) ? field : [field];
  if (l.length === 0) return true;
  const neg = l.filter((x) => typeof x === "string" && x.startsWith("!")).map((x) => x.slice(1));
  const pos = l.filter((x) => typeof x === "string" && !x.startsWith("!"));
  if (neg.includes(want)) return false;
  return pos.length === 0 || pos.includes(want);
}

// ---- lockfiles ---------------------------------------------------------------------------------

// the sha512 of an SRI string ("sha512-... sha1-..."), or "" when it has none
function sha512of(sri) {
  const m = String(sri || "").split(/\s+/).find((x) => /^sha512-[A-Za-z0-9+/]+=*$/.test(x));
  return m || "";
}

function lockOpen(dir) {
  for (const f of ["pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "npm-shrinkwrap.json", "package-lock.json"]) {
    const p = path.join(dir, f);
    if (!fs.existsSync(p)) continue;
    if (f === "bun.lockb" || f === "bun.lock") return { file: f, kind: "unsupported" };
    let text;
    try { text = fs.readFileSync(p, "utf8"); } catch (e) { return { file: f, kind: "unsupported" }; }
    if (f === "yarn.lock") {
      // yarn 2+ (berry) records a checksum of its own zip archives, not of the npm tarball
      if (/^__metadata:/m.test(text)) return { file: f, kind: "unsupported" };
      return { file: f, kind: "yarn", text };
    }
    if (f === "pnpm-lock.yaml") return { file: f, kind: "pnpm", text };
    const j = (() => { try { return JSON.parse(text); } catch (e) { return null; } })();
    if (!j) return { file: f, kind: "unsupported" };
    return { file: f, kind: "npm", json: j };
  }
  return null;
}

// the integrities the lockfile records for name@version (all places it is installed at)
function lockFind(lock, name, ver) {
  const found = new Set();
  let weak = false;
  const add = (sri) => { const s = sha512of(sri); if (s) found.add(s); else if (sri) weak = true; };
  if (lock.kind === "npm") {
    const j = lock.json;
    // v2/v3: "packages" keyed by path ("node_modules/a/node_modules/@s/b"); v1: nested "dependencies"
    if (j.packages && typeof j.packages === "object") {
      for (const [k, v] of Object.entries(j.packages)) {
        if (!v || typeof v !== "object" || v.link) continue;
        const i = k.lastIndexOf("node_modules/");
        if (i < 0 || k.slice(i + 13) !== name || v.version !== ver) continue;
        add(v.integrity);
      }
    } else if (j.dependencies) {
      const walk = (deps) => {
        for (const [k, v] of Object.entries(deps || {})) {
          if (!v || typeof v !== "object") continue;
          if (k === name && v.version === ver) add(v.integrity);
          walk(v.dependencies);
        }
      };
      walk(j.dependencies);
    }
  } else if (lock.kind === "yarn") {
    // blocks: a header line of specifiers ("a@^1", a@1.2.3:), then indented fields
    let hit = false;
    for (const line of lock.text.split(/\r?\n/)) {
      if (/^\S/.test(line)) {
        hit = line.replace(/:\s*$/, "").split(/,\s*/).some((s) => {
          s = s.trim().replace(/^"|"$/g, "");
          const at = s.lastIndexOf("@");
          return at > 0 && s.slice(0, at) === name;
        }) && "pending";
        continue;
      }
      if (!hit) continue;
      let m = line.match(/^\s+version:?\s+"?([^"\s]+)"?\s*$/);
      if (m) { hit = m[1] === ver ? "yes" : false; continue; }
      m = line.match(/^\s+integrity:?\s+"?([^"\s]+)"?\s*$/);
      if (m && hit === "yes") add(m[1]);
    }
  } else if (lock.kind === "pnpm") {
    // packages: keys /a@1.2.3: (v6), /a/1.2.3: (v5), 'a@1.2.3': or a@1.2.3: (v9); its
    // resolution: {integrity: sha512-...} on the lines below, indented further
    const keys = new Set(["/" + name + "@" + ver, "/" + name + "/" + ver, name + "@" + ver]);
    let ind = -1;
    for (const line of lock.text.split(/\r?\n/)) {
      const m = line.match(/^(\s*)(['"]?)([^'"\s:][^'"]*?)\2:\s*$/);
      const lead = line.length - line.trimStart().length;
      if (ind >= 0 && line.trim() !== "" && lead <= ind) ind = -1;
      if (m && keys.has(m[3].replace(/\(.*$/, ""))) { ind = m[1].length; continue; }
      if (ind < 0) continue;
      const r = line.match(/integrity:\s*['"]?([A-Za-z0-9+/=-]+)['"]?/);
      if (r) add(r[1]);
    }
  }
  return { found: [...found], weak };
}

// ---- plan --------------------------------------------------------------------------------------

function plan(stage, cpu, libc, lockdir) {
  const out = [];
  const fail = (m) => out.push("fail\t" + m.replace(/[\t\n]/g, " "));
  const lock = lockOpen(lockdir);
  const want = libc === "musl" ? ["linuxmusl-" + cpu, "linux-" + cpu + "-musl"] : ["linux-" + cpu, "linux-" + cpu + "-gnu"];
  const pkgs = packages(stage, "", []);
  const plat = pkgs.filter((d) => PLAT.test(nameOf(d).replace(/^@[^/]*\//, "")));
  const dests = new Set();
  for (const d of plat) {
    const name = nameOf(d);
    const pj = readJSON(path.join(stage, d, "package.json"));
    if (!pj) continue;   // no metadata: nothing to swap by; the guard looks at its files
    if (pj.os === undefined && pj.cpu === undefined) continue;   // not a platform package
    if (fits(pj.os, "linux") && fits(pj.cpu, cpu) && fits(pj.libc, libc === "musl" ? "musl" : "glibc")) continue;
    if (!validName(name)) { fail(d + ": not a valid npm package name"); continue; }
    if (pj.name !== name) { fail(d + ": its package.json names " + show(pj.name) + " (an alias): tando does not swap it"); continue; }
    const scope = name.startsWith("@") ? name.slice(0, name.indexOf("/") + 1) : "";
    const m = name.slice(scope.length).match(PLAT);
    const cands = want.map((w) => scope + m[1] + w);
    // who installed it: the package that holds this node_modules, and the packages beside it that
    // resolve the name here (not through a copy of their own)
    const nm = d.slice(0, d.lastIndexOf("node_modules/") + 12);
    const holder = nm === "node_modules" ? "" : nm.slice(0, -13);
    const owners = [holder];
    for (const s of pkgs) {
      if (!s.startsWith(nm + "/") || s === d) continue;
      const rest = s.slice(nm.length + 1);
      if (rest.includes("/node_modules/")) continue;
      if (!fs.existsSync(path.join(stage, s, "node_modules", name))) owners.push(s);
    }
    let target = "";
    const pins = [];
    for (const o of owners) {
      const oj = readJSON(path.join(stage, o, "package.json"));
      if (!oj) continue;
      for (const field of ["optionalDependencies", "dependencies"]) {
        const deps = oj[field];
        if (!deps || typeof deps !== "object") continue;
        for (const c of cands) {
          if (!Object.prototype.hasOwnProperty.call(deps, c)) continue;
          target = target || c;
          if (c === target) pins.push({ by: o || "package.json", v: deps[c] });
        }
      }
    }
    if (!target && lock && lock.kind !== "unsupported") {
      for (const c of cands) if (lockFind(lock, c, String(pj.version)).found.length) { target = c; break; }
    }
    if (!target) {
      fail(d + " is built for " + [].concat(pj.os || []).join(",") + "-" + [].concat(pj.cpu || []).join(",") +
        " and no package here pins a build for linux-" + cpu + " (looked for " + cands.join(", ") + ")");
      continue;
    }
    if (!validName(target)) { fail(d + ": no valid package name for linux-" + cpu); continue; }
    // the version: what the installing package pins (exactly), else the package's own version
    // (platform packages are released together, at the same version)
    const badpin = pins.find((p) => !exact(p.v));
    if (badpin) {
      fail((badpin.by === "package.json" ? "package.json" : badpin.by + "/package.json") + " asks for " + target + " " +
        show(badpin.v) + ", not an exact version: tando fetches only exact versions from the registry");
      continue;
    }
    let ver = "";
    const vs = [...new Set(pins.map((p) => p.v))];
    if (vs.length > 1 && vs.includes(pj.version)) ver = pj.version;
    else if (vs.length === 1) ver = vs[0];
    else if (vs.length > 1) { fail(d + ": the packages beside it pin different versions of " + target + " (" + vs.join(", ") + ")"); continue; }
    else if (exact(pj.version)) ver = pj.version;
    else { fail(d + ": its version " + show(pj.version) + " is not an exact version"); continue; }
    const dest = nm + "/" + target;
    let integ = "-", st = "none";
    if (lock && lock.kind === "unsupported") st = "unsupported:" + lock.file;
    else if (lock) {
      const r = lockFind(lock, target, ver);
      if (r.found.length > 1) { fail(lock.file + " records two different checksums for " + target + "@" + ver); continue; }
      if (r.found.length === 1) { integ = r.found[0]; st = "found:" + lock.file; }
      else st = (r.weak ? "weak:" : "absent:") + lock.file;
    }
    if (dests.has(dest)) { out.push(["drop", d, dest].join("\t")); continue; }
    dests.add(dest);
    // installed already (npm install --os=linux --cpu=...): only the other one goes
    const have = readJSON(path.join(stage, dest, "package.json"));
    if (have && have.name === target && have.version === ver) { out.push(["drop", d, dest].join("\t")); continue; }
    out.push(["swap", d, dest, target, ver, integ, st].join("\t"));
  }
  return out;
}

const [cmd, ...a] = process.argv.slice(2);
if (cmd === "plan") {
  const lines = plan(a[0], a[1], a[2], a[3]);
  if (lines.length) process.stdout.write(lines.join("\n") + "\n");
} else if (cmd === "hash") {
  process.stdout.write("sha512-" + crypto.createHash("sha512").update(fs.readFileSync(a[0])).digest("base64") + "\n");
} else if (cmd === "check") {
  const pj = readJSON(path.join(a[0], "package.json"));
  if (!pj || pj.name !== a[1] || pj.version !== a[2]) {
    process.stdout.write("the downloaded package is " + (pj ? show(pj.name) + " " + show(pj.version) : "not an npm package") + "\n");
    process.exit(1);
  }
} else {
  process.stderr.write("usage: native.js plan|hash|check ...\n");
  process.exit(2);
}
