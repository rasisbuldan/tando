// lib/native.js: the planning half of swap_native and native_fix (lib/build.sh). Reads package.json
// files of the staged tree, the project's lockfile and the first bytes of native files; never runs
// anything from them. Node.js is
// there whenever this runs: it is what built the node_modules being swapped, and npm needs it.
//
//   node native.js plan <stage> <cpu> <libc> <lockdir>
//       every npm package in <stage> (any depth of node_modules) whose package.json says it is
//       for another os/cpu/libc than linux-<cpu>-<libc>, and what replaces it. One line each:
//         swap <TAB> from <TAB> dest <TAB> name <TAB> version <TAB> integrity|- <TAB> lock
//         fail <TAB> message
//       lock: found:<file> (integrity is the lockfile's sha512 for name@version), absent:<file>
//       (the lockfile has no sha512 for it), none (no lockfile), unsupported:<file>
//   node native.js fix <stage> <cpu> <libc> <projdir>
//       what is still not right after the swap, per package that holds native code (any depth):
//         inside <TAB> pkg <TAB> detail          the server's binary is in the package
//         prune <TAB> pkg <TAB> file             a binary for another platform beside it (delete it)
//         restore <TAB> pkg <TAB> src <TAB> name <TAB> ver   the project's own copy has it (Next's
//                                                standalone output dropped it): copy src (in projdir)
//         prebuilt <TAB> pkg <TAB> name <TAB> ver   its install script downloads it
//         optional <TAB> pkg <TAB> message       no server binary, but an optional dependency
//         fail <TAB> pkg <TAB> name ver <TAB> why    only compiling on Linux helps
//         note <TAB> prisma <TAB> text
//   node native.js prebuilt <stage> <pkg> <cpu> <libc> <node-major> <tmpdir>
//       downloads the prebuilt binary that the package's own package.json declares (prebuild-install
//       or node-pre-gyp style) into the package: https only, from the declared host only, no
//       redirects (but GitHub's own release hosts), a validated tar. The one place this file
//       writes into the stage. Prints  ok <TAB> url <TAB> glibc|-   or   fail <TAB> refused|none <TAB> why
//   node native.js url <stage> <pkg> <cpu> <libc> <node-major>   the URL it would use (or the refusal)
//   node native.js excused <stage> <cpu> <libc>
//       binaries for other platforms under prebuilds/ of packages that hold the server's own: not
//       a reason for the guard to refuse (the loader picks the right one)
//   node native.js stage <stage> <cpu> <libc> <lockdir> <projdir> <outdir> [noplan]
//       plan, fix and excused in one process, as files in <outdir>; the stdout line says how far it
//       could go while the tree stayed as it is (1: plan only, 2: plan and fix, 3: all three)
//   node native.js hash <file>            the file's sha512, as an SRI string (sha512-<base64>)
//   node native.js check <dir> <name> <version>   the unpacked package is what was asked for
"use strict";
const fs = require("fs");
const os = require("os");
const cp = require("child_process");
const http = require("http");
const https = require("https");
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
const PLAT = /^(.*?)(darwin|linux|linuxmusl|win32|freebsd|openbsd|netbsd|android|sunos|aix)-(x64|arm64|arm|ia32|ppc64|s390x|riscv64|loong64|mips64el|universal)(-(gnu|glibc|musl|msvc|gnueabihf|musleabihf|eabi))?$/;

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

// the platform part of a package name for the server (sharp: linux-x64, swc: linux-x64-gnu,
// @parcel/watcher: linux-x64-glibc, sharp on musl: linuxmusl-x64)
function wantTags(cpu, libc) {
  return libc === "musl" ? ["linuxmusl-" + cpu, "linux-" + cpu + "-musl"] : ["linux-" + cpu, "linux-" + cpu + "-gnu", "linux-" + cpu + "-glibc"];
}

function plan(stage, cpu, libc, lockdir) {
  const out = [];
  const fail = (m) => out.push("fail\t" + m.replace(/[\t\n]/g, " "));
  const lock = lockOpen(lockdir);
  const want = wantTags(cpu, libc);
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
    out.push(["swap", d, dest, target, ver, integ, st, ""].join("\t"));
  }
  // a family of which no piece for the server is installed although another piece is (the laptop's
  // is missing, or only the WebAssembly fallback: @tailwindcss/oxide then runs without its native
  // code and says nothing): add the server's piece, at the version the parent pins
  for (const d of pkgs) {
    const pj = readJSON(path.join(stage, d, "package.json"));
    const opt = pj && pj.optionalDependencies;
    if (!opt || typeof opt !== "object") continue;
    const nm = d.slice(0, d.lastIndexOf("node_modules/") + 12);
    for (const n of Object.keys(opt)) {
      const m = validName(n) && n.replace(/^@[^/]*\//, "").match(PLAT);
      if (!m || !want.includes(m[2] + "-" + m[3] + (m[5] ? "-" + m[5] : ""))) continue;
      if (resolves(stage, d, n)) continue;
      const prefix = n.slice(0, n.length - m[0].length + m[1].length);
      const seen = Object.keys(opt).find((o) => o !== n && o.startsWith(prefix) && resolves(stage, d, o));
      if (!seen) continue;   // nothing of the family is installed: the parent does not use it here
      const dest = nm + "/" + n;
      if (dests.has(dest)) continue;
      if (!exact(opt[n])) {
        fail(d + "/package.json asks for " + n + " " + show(opt[n]) + ", not an exact version: tando fetches only exact versions from the registry");
        continue;
      }
      let integ = "-", st = "none";
      if (lock && lock.kind === "unsupported") st = "unsupported:" + lock.file;
      else if (lock) {
        const r = lockFind(lock, n, opt[n]);
        if (r.found.length > 1) { fail(lock.file + " records two different checksums for " + n + "@" + opt[n]); continue; }
        if (r.found.length === 1) { integ = r.found[0]; st = "found:" + lock.file; }
        else st = (r.weak ? "weak:" : "absent:") + lock.file;
      }
      dests.add(dest);
      const why = /wasm|wasi/.test(seen) ? "it was running its WebAssembly fallback (" + seen.slice(prefix.length) + ")" :
        "its build for linux-" + cpu + " was not installed";
      out.push(["swap", "-", dest, n, opt[n], integ, st, why].join("\t"));
    }
  }
  return out;
}

// is <name> found from the package at <d> the way node resolves it (its own node_modules, then each
// holder's, up to the top)
function resolves(root, d, name) {
  let cur = d;
  for (;;) {
    if (fs.existsSync(path.join(root, cur, "node_modules", name, "package.json"))) return true;
    const i = cur.lastIndexOf("node_modules/");
    if (i <= 0) return fs.existsSync(path.join(root, "node_modules", name, "package.json"));
    cur = cur.slice(0, i - 1);
  }
}

// ---- native code in the staged packages -------------------------------------------------------

// what a native file is, from its first bytes: elf-x64, elf-arm64, elf-other, macho, pe, other
function fileKind(f) {
  const b = Buffer.alloc(20);
  let fd;
  try { fd = fs.openSync(f, "r"); fs.readSync(fd, b, 0, 20, 0); } catch (e) { return "other"; } finally {
    if (fd !== undefined) try { fs.closeSync(fd); } catch (e) { /* nothing to do */ }
  }
  if (b[0] === 0x7f && b[1] === 0x45 && b[2] === 0x4c && b[3] === 0x46) {
    const m = b[5] === 2 ? b.readUInt16BE(18) : b.readUInt16LE(18);
    return m === 0x3e ? "elf-x64" : m === 0xb7 ? "elf-arm64" : "elf-other";
  }
  const m4 = b.readUInt32BE(0);
  if (m4 === 0xcffaedfe || m4 === 0xcefaedfe || m4 === 0xfeedfacf || m4 === 0xfeedface || m4 === 0xcafebabe) return "macho";
  if (b[0] === 0x4d && b[1] === 0x5a) return "pe";
  return "other";
}
const NATIVE_FILE = /\.(node|dylib|so)$|\.so\.[0-9]|\.dll$/;
const NATIVE_SCRIPT = /node-gyp|prebuild-install|node-pre-gyp|cmake-js|install-from-cache|install-artifact-from-github/;

// the files of a package that are native code (nested node_modules are other packages)
function nativeFiles(dir, rel, out) {
  for (const e of list(path.join(dir, rel))) {
    if (e === "node_modules" || e === ".bin") continue;
    const r = rel ? rel + "/" + e : e;
    let st;
    try { st = fs.lstatSync(path.join(dir, r)); } catch (x) { continue; }
    if (st.isDirectory()) nativeFiles(dir, r, out);
    else if (st.isFile() && NATIVE_FILE.test(e)) out.push({ rel: r, kind: fileKind(path.join(dir, r)) });
  }
  return out;
}

function hasServerFile(files, cpu, libc) {
  return files.some((f) => f.kind === "elf-" + cpu && (libc === "musl" ? /musl/i.test(f.rel) : !/musl/i.test(f.rel)));
}

let memo = null;   // set by the stage command: one walk of each package for fix and excused
function analyse(stage, d, cpu, libc) {
  if (memo && memo.has(d)) return memo.get(d);
  const r = analyse1(stage, d, cpu, libc);
  if (memo) memo.set(d, r);
  return r;
}
function analyse1(stage, d, cpu, libc) {
  const dir = path.join(stage, d);
  const pj = readJSON(path.join(dir, "package.json")) || {};
  const files = nativeFiles(dir, "", []);
  const sc = pj.scripts && typeof pj.scripts === "object" ? ["preinstall", "install", "postinstall"].map((k) => pj.scripts[k]).filter((x) => typeof x === "string").join(" ; ") : "";
  const prebuilds = isDir(path.join(dir, "prebuilds"));
  return {
    pj, files, scripts: sc, prebuilds,
    marker: files.length > 0 || prebuilds || NATIVE_SCRIPT.test(sc) || pj.gypfile === true || fs.existsSync(path.join(dir, "binding.gyp")),
    server: files.filter((f) => f.kind === "elf-" + cpu && (libc === "musl" ? /musl/i.test(f.rel) : !/musl/i.test(f.rel))),
    foreign: files.filter((f) => f.kind !== "elf-" + cpu),
  };
}

// the binary comes from a platform package installed beside (msgpackr-extract, @parcel/watcher)
function viaPlatform(stage, d, pj, cpu, libc) {
  const opt = pj.optionalDependencies;
  if (!opt || typeof opt !== "object") return "";
  const want = wantTags(cpu, libc);
  for (const n of Object.keys(opt)) {
    const m = validName(n) && n.replace(/^@[^/]*\//, "").match(PLAT);
    if (m && want.includes(m[2] + "-" + m[3] + (m[5] ? "-" + m[5] : "")) && resolves(stage, d, n)) return n;
  }
  return "";
}

// a native package of the project's own node_modules with the same name and version, holding the
// server's binary: where Next's standalone output pruned it
function projectCopy(stage, d, name, ver, proj, cpu, libc) {
  if (!proj) return "";
  for (const rel of [d, "node_modules/" + name]) {
    const dir = path.join(proj, rel);
    if (path.resolve(dir) === path.resolve(path.join(stage, d))) continue;
    const pj = readJSON(path.join(dir, "package.json"));
    if (!pj || pj.name !== name || pj.version !== ver) continue;
    if (hasServerFile(nativeFiles(dir, "", []), cpu, libc)) return rel;
  }
  return "";
}

function fixPlan(stage, cpu, libc, proj) {
  const out = [];
  const pkgs = packages(stage, "", []);
  const optional = new Set(), required = new Set();
  for (const d of pkgs.concat([""])) {
    const pj = readJSON(path.join(stage, d, "package.json"));
    if (!pj) continue;
    for (const k of Object.keys(pj.optionalDependencies || {})) optional.add(k);
    for (const f of ["dependencies", "peerDependencies"]) for (const k of Object.keys(pj[f] || {})) required.add(k);
  }
  for (const d of pkgs) {
    const name = nameOf(d);
    const pj0 = readJSON(path.join(stage, d, "package.json"));
    if (!pj0) continue;
    // a platform package: it fits the server (the swap left it) or it does not (the guard says so)
    if (pj0.os !== undefined || pj0.cpu !== undefined) continue;
    const a = analyse(stage, d, cpu, libc);
    if (!a.marker) continue;
    const ver = String(a.pj.version);
    if (a.server.length) {
      out.push(["inside", d, a.server[0].rel].join("\t"));
      for (const f of a.foreign) out.push(["prune", d, d + "/" + f.rel].join("\t"));
      continue;
    }
    if (viaPlatform(stage, d, a.pj, cpu, libc)) continue;
    const src = projectCopy(stage, d, name, ver, proj, cpu, libc);
    if (src) { out.push(["restore", d, src, name, ver].join("\t")); continue; }
    const mech = /prebuild-install/.test(a.scripts) ? "prebuild-install" : /node-pre-gyp/.test(a.scripts) ? "node-pre-gyp" : "";
    let why;
    if (mech && !(name === "sharp" && /^0\.(?:[0-9]|[12][0-9]|3[0-2])\./.test(ver))) {
      out.push(["prebuilt", d, name, ver].join("\t"));
      continue;
    }
    if (mech) why = "sharp before 0.33 downloads libvips separately at install: use sharp 0.33 or later";
    else if (a.prebuilds) {
      const other = list(path.join(stage, d, "prebuilds")).map((x) => x.replace(/\.node$/, "")).join(", ");
      why = "ships prebuilt binaries for other platforms only (" + other.slice(0, 80) + "), none for linux-" + cpu + "; it is compiled on Linux";
    } else if (NATIVE_SCRIPT.test(a.scripts) || a.pj.gypfile === true || fs.existsSync(path.join(stage, d, "binding.gyp"))) {
      why = "it is compiled when installed (" + (NATIVE_SCRIPT.exec(a.scripts) || ["node-gyp"])[0] + ") and ships no binary for linux-" + cpu;
    } else why = "it holds native code for other platforms only";
    const msg = [name + " " + ver, why].map((x) => x.replace(/[\t\n]/g, " ")).join("\t");
    if (optional.has(name) && !required.has(name)) {
      out.push(["optional", d, name + " " + ver + " has no binary for linux-" + cpu + " (" + why + "); it is an optional dependency, its parent has to cope without it"].join("\t"));
    } else out.push(["fail", d, msg].join("\t"));
  }
  // Prisma: nothing to swap, one note
  for (const n of ["@prisma/client", "prisma"]) {
    const pj = readJSON(path.join(stage, "node_modules", n, "package.json"));
    if (pj) { out.push(["note", "prisma", String(pj.version).replace(/[^0-9A-Za-z.-]/g, "").slice(0, 20)].join("\t")); break; }
  }
  return out;
}

function excused(stage, cpu, libc) {
  const out = [];
  for (const d of packages(stage, "", [])) {
    const a = analyse(stage, d, cpu, libc);
    if (!a.server.length) continue;
    for (const f of a.foreign) if (/(^|\/)prebuilds\//.test(f.rel)) out.push(d + "/" + f.rel);
  }
  return out;
}

// stage <stage> <cpu> <libc> <lockdir> <projdir> <outdir> [noplan]: plan, fix and excused in one process
// (one start, one walk of the staged tree), written as files into <outdir>; prints the level reached:
//   1  plan written and it has swaps/drops/failures (the tree is about to change: nothing further)
//   2  plan and fix written, the fix has work to do (restore, prebuilt, prune, fail): the tree changes
//   3  plan, fix and excused written and the tree needs nothing more, so they stay true
// With noplan the plan is skipped (the shell has done its swaps; the tree is as it is now).
function stageAll(stage, cpu, libc, lockdir, proj, outdir, noplan) {
  const w = (n, lines) => fs.writeFileSync(path.join(outdir, n), lines.length ? lines.join("\n") + "\n" : "");
  memo = new Map();
  if (!noplan) {
    const pl = plan(stage, cpu, libc, lockdir);
    w("plan", pl);
    if (pl.some((l) => /^(swap|drop|fail)\t/.test(l))) return 1;
  }
  const fx = fixPlan(stage, cpu, libc, proj);
  w("fix", fx);
  if (fx.some((l) => /^(restore|prebuilt|prune|fail)\t/.test(l))) return 2;
  let ex = [];
  try { ex = excused(stage, cpu, libc); } catch (e) { ex = []; }
  w("excused", ex);
  return 3;
}

// ---- prebuilt downloads (prebuild-install and node-pre-gyp style) ---------------------------------
// The one thing here that is not covered by the lockfile: the package's own package.json says where
// its binary is. Nothing from it is run; the URL is built from validated fields only.

const ABI = { 18: 108, 20: 115, 21: 120, 22: 127, 23: 131, 24: 137, 25: 141 };
const GITHUB_RELEASES = ["objects.githubusercontent.com", "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"];
const TEST_LOCAL = () => process.env.TANDO_NATIVE_TEST_ALLOW_LOCAL === "1";
const refused = (m) => { const e = new Error(m); e.kind = "refused"; return e; };
const none = (m) => { const e = new Error(m); e.kind = "none"; return e; };

function repoPath(pj) {   // "owner/repo" of a GitHub repository field, else ""
  let u = pj.repository;
  if (u && typeof u === "object") u = u.url;
  if (typeof u !== "string") return "";
  const m = u.trim().match(/^(?:git\+)?(?:https?:\/\/|git:\/\/|ssh:\/\/git@|git@|github:)?(?:github\.com[/:])?([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?\/?$/);
  return m && (/github/.test(u) || /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(u.trim())) ? m[1] + "/" + m[2] : "";
}

function fillTemplate(t, vars, what) {
  if (typeof t !== "string" || t.length > 300) throw refused(what + " is not a short text");
  return t.replace(/\{([a-z_]+)\}/g, (all, k) => {
    if (!Object.prototype.hasOwnProperty.call(vars, k)) throw refused(what + " uses {" + k + "}, which tando does not know");
    return vars[k];
  });
}

// -> { url, mech, modulePath }
function prebuiltUrl(pj, cpu, libc, nodeMajor) {
  const scripts = pj.scripts && typeof pj.scripts === "object" ? ["preinstall", "install", "postinstall"].map((k) => pj.scripts[k]).filter((x) => typeof x === "string").join(" ; ") : "";
  const mech = /prebuild-install/.test(scripts) ? "pi" : /node-pre-gyp/.test(scripts) ? "npg" : "";
  if (!mech) throw none("its install script is not prebuild-install or node-pre-gyp");
  if (!exact(pj.version)) throw refused("its version " + show(pj.version) + " is not an exact version");
  const bin = pj.binary && typeof pj.binary === "object" ? pj.binary : {};
  const napis = Array.isArray(bin.napi_versions) ? bin.napi_versions.filter((n) => Number.isInteger(n) && n > 0 && n < 100) : [];
  let abi, runtime, nodeAbi;
  if (napis.length) { abi = String(Math.max(...napis)); runtime = "napi"; nodeAbi = "napi-v" + abi; }
  else {
    abi = ABI[nodeMajor];
    if (!abi) throw none("this binary is built per Node version and tando does not know the ABI of Node " + show(nodeMajor));
    abi = String(abi); runtime = "node"; nodeAbi = "node-v" + abi;
  }
  const name = String(pj.name).replace(/^@[^/]*\//, "");
  const vars = {
    name, version: pj.version, abi, runtime, node_abi: nodeAbi, napi_build_version: napis.length ? abi : "", platform: "linux", arch: cpu,
    libc: mech === "pi" ? (libc === "musl" ? "musl" : "") : (libc === "musl" ? "musl" : "glibc"),
    configuration: "Release", toolset: "", tag_prefix: "v", module_name: "",
  };
  if (typeof bin.module_name === "string") {
    if (!/^[A-Za-z0-9_.-]{1,80}$/.test(bin.module_name)) throw refused("binary.module_name is not a plain name");
    vars.module_name = bin.module_name;
  }
  let host, remote = "", file;
  const fallback = "{name}-v{version}-" + (mech === "pi" ? "{runtime}-v{abi}-{platform}{libc}-{arch}" : "{node_abi}-{platform}-{arch}") + ".tar.gz";
  if (typeof bin.host === "string") {
    host = bin.host;
    if (bin.remote_path !== undefined) remote = fillTemplate(bin.remote_path, vars, "binary.remote_path");
    file = fillTemplate(bin.package_name !== undefined ? bin.package_name : fallback, vars, "binary.package_name");
  } else if (mech === "pi") {
    const repo = repoPath(pj);
    if (!repo) throw refused("it declares neither binary.host nor a GitHub repository to download from");
    host = "https://github.com/" + repo + "/releases/download/";
    remote = "v" + pj.version;
    file = fillTemplate(fallback, vars, "the file name");
  } else throw refused("it declares no binary.host");
  let u;
  try { u = new URL(host); } catch (e) { throw refused("binary.host " + show(host) + " is not a URL"); }
  if (u.protocol !== "https:" && !(TEST_LOCAL() && u.protocol === "http:")) throw refused("the declared host " + show(host) + " is not https");
  if (u.username || u.password || u.search || u.hash) throw refused("the declared host has credentials or a query");
  const hn = u.hostname;
  const local = hn === "localhost" || hn === "127.0.0.1";
  if (!(TEST_LOCAL() && local)) {
    if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(hn) || /^[0-9.]+$/.test(hn) || /\.(local|internal|localhost)$/.test(hn))
      throw refused("the declared host " + show(hn) + " is not a public domain name");
    if (u.port) throw refused("the declared host has a port");
  }
  const segs = [].concat(u.pathname.split("/"), remote.split("/"), file.split("/")).filter((x) => x !== "" && x !== ".");
  for (const x of segs) if (!/^[A-Za-z0-9._~+-]+$/.test(x) || x === "..") throw refused("the download path has a part tando does not accept: " + show(x));
  if (!/\.(tar\.gz|tgz)$/.test(file)) throw refused("the file name is not a .tar.gz");
  let modulePath = "";
  if (mech === "npg") {
    if (typeof bin.module_path !== "string") throw refused("it declares no binary.module_path");
    modulePath = fillTemplate(bin.module_path, vars, "binary.module_path").replace(/^\.\//, "").replace(/\/+$/, "");
    if (!modulePath || modulePath.split("/").some((x) => !/^[A-Za-z0-9._-]+$/.test(x) || x === "." || x === "..")) throw refused("binary.module_path is not a plain relative path");
  }
  return { url: u.origin + "/" + segs.join("/"), mech, modulePath, local: TEST_LOCAL() && local, github: hn === "github.com" };
}

function download(spec, dest) {
  return new Promise((resolve, reject) => {
    const u = new URL(spec.url);
    const mod = u.protocol === "https:" ? https : http;
    const req = mod.get(u, { headers: { "user-agent": "tando", accept: "application/octet-stream" } }, (res) => {
      const st = res.statusCode;
      if (st >= 300 && st < 400) {
        res.resume();
        let to = "";
        try { to = new URL(res.headers.location || "", u); } catch (e) { /* refused below */ }
        if (spec.github && !spec.hop && to && to.protocol === "https:" && GITHUB_RELEASES.includes(to.hostname) && !to.username && !to.port) {
          download({ url: to.href, hop: true }, dest).then(resolve, reject);
          return;
        }
        return reject(refused("the host redirects to " + show(to ? to.hostname || to.href : res.headers.location) + ": tando follows no redirects except GitHub's own release hosts"));
      }
      if (st === 404 || st === 403) { res.resume(); return reject(none("no prebuilt binary is published at " + spec.url + " (HTTP " + st + ")")); }
      if (st !== 200) { res.resume(); return reject(none("HTTP " + st + " from " + u.hostname)); }
      const max = 300 * 1024 * 1024;
      let n = 0;
      const out = fs.createWriteStream(dest);
      res.on("data", (c) => { n += c.length; if (n > max) { req.destroy(new Error("the download is larger than 300 MB")); } });
      res.pipe(out);
      out.on("finish", () => resolve(n));
      res.on("error", reject);
    });
    req.setTimeout(30000, () => req.destroy(new Error("the download timed out")));
    req.on("error", reject);
  });
}

// the tarball's entries: plain files and directories under <prefix> only
function tarEntries(file, prefix) {
  const names = cp.execFileSync("tar", ["-tzf", file], { encoding: "utf8", maxBuffer: 64 << 20 }).split("\n").filter(Boolean);
  const types = cp.execFileSync("tar", ["-tvzf", file], { encoding: "utf8", maxBuffer: 64 << 20 }).split("\n").filter(Boolean);
  if (!names.length || names.length !== types.length) throw refused("the downloaded archive is not a readable tar");
  names.forEach((n, i) => {
    const t = types[i][0];
    if (t !== "-" && t !== "d") throw refused("the downloaded archive holds something that is not a plain file: " + show(n));
    if (/^\/|(^|\/)\.\.(\/|$)|[\\\0-\x1f]/.test(n)) throw refused("the downloaded archive has an unsafe path: " + show(n));
    if (!(n === prefix || n.startsWith(prefix + "/") || n.replace(/^\.\//, "") === prefix || n.replace(/^\.\//, "").startsWith(prefix + "/")))
      throw refused("the downloaded archive has a file outside " + prefix + "/: " + show(n));
  });
}

function maxGlibc(files) {
  let best = [0, 0];
  for (const f of files) {
    const s = fs.readFileSync(f, "latin1");
    for (const m of s.matchAll(/GLIBC_(\d+)\.(\d+)/g)) {
      const v = [Number(m[1]), Number(m[2])];
      if (v[0] > best[0] || (v[0] === best[0] && v[1] > best[1])) best = v;
    }
  }
  return best[0] ? best.join(".") : "-";
}

async function prebuilt(stage, d, cpu, libc, major, tmp) {
  const dir = path.join(stage, d);
  const pj = readJSON(path.join(dir, "package.json"));
  if (!pj) throw none("no package.json");
  const spec = prebuiltUrl(pj, cpu, libc, major);
  fs.mkdirSync(tmp, { recursive: true });
  const file = path.join(tmp, "prebuilt.tgz");
  await download(spec, file);
  let dest = dir, prefix = "build";
  if (spec.mech === "npg") { dest = path.join(dir, path.dirname(spec.modulePath)); prefix = path.basename(spec.modulePath); fs.mkdirSync(dest, { recursive: true }); }
  tarEntries(file, prefix);
  // what was built for this machine goes (a binary for another platform must not stay beside it)
  for (const f of analyse(stage, d, cpu, libc).foreign) fs.rmSync(path.join(dir, f.rel), { force: true });
  cp.execFileSync("tar", ["-xzf", file, "-C", dest, "--no-same-owner"], { stdio: "ignore" });
  const a = analyse(stage, d, cpu, libc);
  if (!a.server.length) throw none("the downloaded archive holds no binary for linux-" + cpu);
  return { url: spec.url, glibc: maxGlibc(a.server.map((f) => path.join(dir, f.rel))) };
}

const [cmd, ...a] = process.argv.slice(2);
if (cmd === "plan") {
  const lines = plan(a[0], a[1], a[2], a[3]);
  if (lines.length) process.stdout.write(lines.join("\n") + "\n");
} else if (cmd === "fix") {
  const lines = fixPlan(a[0], a[1], a[2], a[3]);
  if (lines.length) process.stdout.write(lines.join("\n") + "\n");
} else if (cmd === "stage") {
  process.stdout.write(stageAll(a[0], a[1], a[2], a[3], a[4], a[5], a[6] === "noplan") + "\n");
} else if (cmd === "excused") {
  const lines = excused(a[0], a[1], a[2]);
  if (lines.length) process.stdout.write(lines.join("\n") + "\n");
} else if (cmd === "url") {
  try {
    const pj = readJSON(path.join(a[0], a[1], "package.json"));
    process.stdout.write(prebuiltUrl(pj || {}, a[2], a[3], a[4]).url + "\n");
  } catch (e) { process.stdout.write("refused: " + e.message + "\n"); process.exit(1); }
} else if (cmd === "prebuilt") {
  prebuilt(a[0], a[1], a[2], a[3], a[4], a[5]).then(
    (r) => process.stdout.write(["ok", r.url, r.glibc].join("\t") + "\n"),
    (e) => { process.stdout.write(["fail", e.kind || "none", String(e.message).replace(/[\t\n]/g, " ").slice(0, 300)].join("\t") + "\n"); });
} else if (cmd === "hash") {
  process.stdout.write("sha512-" + crypto.createHash("sha512").update(fs.readFileSync(a[0])).digest("base64") + "\n");
} else if (cmd === "check") {
  const pj = readJSON(path.join(a[0], "package.json"));
  if (!pj || pj.name !== a[1] || pj.version !== a[2]) {
    process.stdout.write("the downloaded package is " + (pj ? show(pj.name) + " " + show(pj.version) : "not an npm package") + "\n");
    process.exit(1);
  }
} else {
  process.stderr.write("usage: native.js plan|fix|prebuilt|url|excused|hash|check ...\n");
  process.exit(2);
}
