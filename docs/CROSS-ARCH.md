# Building on one machine, running on another

tando builds on your machine (often a Mac with Apple silicon) and runs the release on a Linux
server (x86-64 or arm64). Plain JavaScript runs anywhere. Native code (`.node`, `.so`, `.dylib`
files) runs only on the platform it was built for. This page says what tando does about it, what
it cannot do, and what to do when a deploy stops.

## What tando does at every deploy

1. **Swap platform packages.** Many npm packages ship their native code as one small package per
   platform (`@img/sharp-darwin-arm64`, `@img/sharp-linux-x64`, ...). npm installs only the one
   for your machine. tando finds every such package for another platform, at any depth of
   `node_modules` (also a copy nested under `node_modules/next/node_modules`). It puts the package
   for the server's platform in the same `node_modules`. A package counts when its `package.json`
   has `os` or `cpu` fields that do not fit the server.
2. **Pick the version.** The version is the exact version that the package beside it pins in
   `optionalDependencies`, or else the package's own version. Ranges, tags, URLs, git and file
   specs are refused, and tando never passes them to npm.
3. **Fetch and verify.** tando fetches the package with `npm pack <name>@<version>` from the
   registry npm uses here (your `.npmrc` applies; install scripts do not run). The file is checked
   against the sha512 in your lockfile:

   | Lockfile | Checked |
   |---|---|
   | `package-lock.json`, `npm-shrinkwrap.json` (v1, v2, v3, nested paths too) | yes |
   | `yarn.lock` (yarn 1) | yes |
   | `pnpm-lock.yaml` | yes (but see pnpm below) |
   | `yarn.lock` (yarn 2+), `bun.lock`, `bun.lockb` | no: tando cannot read their checksums |

   If the file does not match, the deploy stops and nothing is uploaded. If there is no lockfile,
   the lockfile has no entry for the package, or tando cannot read it, the package is still
   swapped. The deploy box then says `not verified` and why, in yellow. Each swapped package is
   one line: `swapped <path> for <package> <version>, verified against package-lock.json`.
4. **Cache.** Tarballs are kept in `.tando/cache` next to their sha512. A cached file whose checksum
   has changed is fetched again. A cached file is checked against the lockfile on every deploy.
5. **Fix the packages that are not platform packages** (after the swap, before the guard). Every
   package in the release that holds native code must hold the server's binary. By how the package
   ships it:

   | How the package ships its binary | What tando does | Shown as |
   |---|---|---|
   | The binaries of several platforms inside it (`prebuilds/<platform>-<arch>/`, or `prebuilds/<platform>-<arch>.node`: node-gyp-build, better-sqlite3 13, bcrypt 6, argon2, bufferutil, utf-8-validate) | Nothing to fetch. The files for other platforms are deleted from the release (the loader never picks them; they only cost space and would trip the guard). | `already inside the package (...; N files for other platforms removed)` |
   | The same, but Next's standalone output kept only your machine's architecture (the server's file is gone) | The whole package is copied back from your project's `node_modules`, when it has the same name and version and holds the server's binary. | `restored from node_modules (name version; ...)` |
   | Downloaded when the package installs, by `prebuild-install` or `node-pre-gyp` (sqlite3, canvas, bcrypt 5) | tando downloads the server's binary from the host the package's own `package.json` declares, into the release only. See "Downloaded binaries" below. | `downloaded prebuilt for linux-x64 from <host> (not verified by the lockfile)` |
   | Compiled when the package installs (node-pty, a plain `node-gyp` module) and no binary for the server exists | The deploy stops before anything is uploaded and names the module, why, and the two ways out: `tando ci github`, or (not available yet) a build in a Linux container. | stop |
   | An optional dependency of another package that cannot be had for the server | Not a stop: its parent has to cope without it (ssh2 and cpu-features do). Said in the output. | `not verified: ... optional dependency` |

   A package whose binary comes from a platform package beside it (msgpackr-extract,
   @parcel/watcher) needs nothing more than step 1.
   A platform package that is *missing* is added too, even when no package for another platform is
   there: `@tailwindcss/oxide` falls back to WebAssembly without a word when its Linux binary is
   not installed; tando adds the Linux package and says `it was running its WebAssembly fallback`.
   (A family of which nothing at all is installed, such as Next's `@next/swc-*` in a standalone
   build, is left alone.)
6. **Guard.** If any native file in the release is still not built for the server, nothing is
   uploaded. tando prints every such file, why it could not swap it, and what to do. A file for
   another platform under `prebuilds/` of a package that holds the server's own is accepted. A
   project `.npmrc` (it can carry a registry token) is never copied into a release, and the guard
   refuses a release that has one, like `.env*`.
7. **Prisma.** When `@prisma/client` or `prisma` is in the release, one line: Prisma 7 has no
   engine binary to swap; `prisma migrate deploy` on the server needs
   `PRISMA_CLI_BINARY_TARGETS=<target>` (the line names it) and libssl3 on the server. Older
   Prisma keeps its query engine as a binary: the guard says when it is for another platform.
8. **Pre-flight on the server (Next.js).** The new release loads `sharp` as Next.js resolves it
   (from Next's own directory, as the app's user, in its sandbox). Every other copy of `sharp`
   in the release must load too (a copy shipped without its code, only its `package.json`, is
   skipped: nothing can load it). The error names the copy that failed.

`tando deploy --dry-run` does steps 1 to 7 and shows the same lines without uploading.

All of this runs on your machine, without a container: nothing is compiled and nothing runs under
emulation (why: "Timing" below). The deploy box has one line per module, for example:

```
swapped node_modules/@img/sharp-darwin-arm64 for @img/sharp-linux-x64 0.35.5, verified against package-lock.json
node_modules/better-sqlite3: restored from node_modules (better-sqlite3 13.2.0; ...)
node_modules/bcrypt: already inside the package (prebuilds/linux-x64/...; 3 files for other platforms removed)
node_modules/sqlite3: downloaded prebuilt for linux-x64 from github.com (not verified by the lockfile)
```

## Downloaded binaries: what is trusted

A binary that `prebuild-install` or `node-pre-gyp` would download at install is **not covered by
the lockfile**: the lockfile records the npm tarball, not a file on GitHub. tando says so for
each one (`not verified by the lockfile`, in yellow). What it does to keep that small:

- It never runs the package's install script, `prebuild-install` or `node-pre-gyp`. It builds the
  URL itself from the package's `package.json`: `binary.host`, `binary.remote_path`,
  `binary.package_name` and `binary.module_path` (node-pre-gyp), or, with no `binary.host`, the
  GitHub repository in `repository` and prebuild-install's file name
  (`<name>-v<version>-napi-v<N>-linux-x64.tar.gz`, or `...-node-v<ABI>-...` for packages built per
  Node version; the ABI is the one of the server's Node).
- The host must be the one the package declares, `https`, a public domain name (no IP address, no
  `localhost`, no credentials or port). The path parts may hold letters, digits and `._~+-` only.
  Only `{name}`, `{version}`, `{abi}`, `{runtime}`, `{platform}`, `{arch}`, `{libc}`,
  `{node_abi}`, `{napi_build_version}`, `{module_name}`, `{configuration}`, `{toolset}` and
  `{tag_prefix}` are filled in; any other `{...}` stops the deploy.
- A redirect is refused, except from github.com to GitHub's own release hosts
  (`release-assets.githubusercontent.com` and two older names), https only.
- The archive must be a plain tar of files and directories under `build/` (prebuild-install) or
  under the last part of `binary.module_path` (node-pre-gyp): no absolute path, no `..`, no link.
  At most 300 MB.
- Binaries built on your machine in the same package (`build/Release/*.node`, `.dylib`) are
  deleted before the download is unpacked.
- The downloaded binary must then be an ELF file for the server's CPU, or the deploy stops.
- Nothing is cached: a download takes about a second.

That is the trust you already give `npm install` for these packages (it downloads from the same
host), minus running their scripts. If you need it verified, build on Linux (`tando ci github`)
or use a package that ships its binaries in the npm tarball.

**The server's Node and glibc.** A binary built per Node version (`node-v137`) is fetched for the
server's Node major, so `node` in `tando.conf` and the server must agree (tando says when they
do not). A prebuilt can also need a newer glibc than the server has (sqlite3 6: glibc 2.38, so
Ubuntu 24.04 yes, Debian 12 no). tando reads the highest `GLIBC_x.y` the binary names. When the
server's glibc is known, the deploy stops if it is lower. `tando-agent info` does not report the
glibc version yet; until it does, tando prints `needs glibc 2.38 or newer: tando cannot read the
server's glibc yet` when the need is above 2.31, and goes on.

## Coverage

Measured with Node 24 on an Apple-silicon laptop against Linux x86-64 images of Debian 12 and
Ubuntu 24.04, each module loaded and called on the server (versions of November 2026):

| Module class | What tando does | Verified |
|---|---|---|
| sharp (`@img/sharp-*` and libvips), esbuild, lightningcss, @swc/core, @next/swc, Rollup | Swap of platform packages (step 1) | loaded on the server |
| @tailwindcss/oxide | Swap; adds the Linux package when only the WebAssembly fallback is installed | native build loaded (without it: WASM, silently) |
| @parcel/watcher (`-linux-x64-glibc`), @node-rs/argon2 and bcrypt, @libsql/client, msgpackr-extract | Swap by the same rule, or already installed beside the package | loaded on the server |
| better-sqlite3 13, bcrypt 6, argon2, bufferutil, utf-8-validate | Inside the package; others deleted; restored when Next's output pruned it | loaded on the server; `test/e2e-next.sh` N11 with a route |
| better-sqlite3 12 (via an adapter), sqlite3 6, canvas 3 (bundles cairo and pango), bcrypt 5 | Downloaded prebuilt | loaded on the server in the experiment; tando's URLs and downloads for sqlite3, canvas and bcrypt 5 checked against GitHub; the tests use a stub host |
| Prisma 7 | Nothing; a note | CRUD through an adapter, `migrate deploy` with the target |
| node-pty 1.1 (compiles on Linux) | Stops before upload | refused; the fork `@lydell/node-pty` ships Linux packages and works through step 1 |

Not handled:

- Packages that need a compiler on Linux and ship no Linux binary: the deploy stops (above).
- `re2` and anything else that downloads with `install-from-cache` or
  `install-artifact-from-github`: not supported; it stops as "compiled when installed".
- sharp before 0.33 (it downloads libvips by itself): stops; use 0.33 or later.
- A prebuilt that needs system libraries the server lacks (Prisma's `migrate deploy` needs
  libssl3; canvas and sharp bundle theirs).
- pnpm's default `node_modules/.pnpm` layout (build on Linux, or set `node-linker=hoisted`), and
  packages that exist only for macOS and are not platform packages, such as `fsevents`: the guard
  still refuses them.

## Timing: why there is no container build

Measured once, on one machine (Apple silicon, OrbStack with Rosetta; the machine was loaded, load
average 25 to 100; median of 3; read every ratio as plus or minus 30%):

| App | Local build and swap (this page) | Build in an x86-64 container |
|---|---|---|
| Next app with sharp and better-sqlite3 | 27 s | 51 s (`npm ci` 30 s, `next build` 22 s) |
| The same with 150 more pages and more packages | 41 s | 82 s |

A build under emulation takes about 3 times as long as a local one (`next build` 3.0 and 3.1
times, `npm ci` about 3 times), and the first container build also pulls a 410 MB image. The swap
takes about half the time of the container build. A container build is therefore not part of
tando: it would make deploys slower for modules that now need nothing.

## When the deploy stops

- **A nested copy (Next.js and sharp).** Your `package.json` asks for one version of sharp and Next
  asks for another, so npm installs both, one under `node_modules/next/node_modules`. tando
  swaps both. To keep only one copy, use the version Next asks for (`npm ls sharp` shows both).
- **You do not need optimised images.** `images: { unoptimized: true }` in `next.config.*` means
  Next never loads sharp.
- **Anything else, or you want Linux builds.** `tando ci github` writes a GitHub Actions workflow
  that builds on Linux and deploys from there (docs/CI.md).
- **`not verified` in the output.** Commit a lockfile that tando can read (see the table above).
