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
5. **Guard.** If any native file in the release is still not built for the server, nothing is
   uploaded. tando prints every such file, why it could not swap it, and what to do.
6. **Pre-flight on the server (Next.js).** The new release loads `sharp` as Next.js resolves it
   (from Next's own directory, as the app's user, in its sandbox). Every other copy of `sharp`
   in the release must load too (a copy shipped without its code, only its `package.json`, is
   skipped: nothing can load it). The error names the copy that failed.

`tando deploy --dry-run` does steps 1 to 5 and shows the result without uploading.

## Families

| Package family | Handled |
|---|---|
| sharp (`@img/sharp-*`, `@img/sharp-libvips-*`) | yes: swapped and pre-flight tested |
| Next.js compiler (`@next/swc-*`; a standalone build does not ship it) | yes: swapped |
| esbuild (`@esbuild/*`), Rollup (`@rollup/rollup-*`), Lightning CSS (`lightningcss-*`), SWC (`@swc/core-*`), Tailwind's oxide, Parcel's watcher | yes: same convention (`os`/`cpu` in package.json, pinned by the parent) |
| Prisma engines (`.prisma/client/*query_engine*`) | no: Prisma downloads them at `prisma generate`. Add the server's target to `binaryTargets` in `schema.prisma` (the guard prints it) |
| Packages compiled at install, such as `better-sqlite3`, `bcrypt` and `canvas` (`build/Release/*.node`, prebuild downloads) | no: install on Linux |
| Packages with `prebuilds/<platform>/` for several platforms | no: the guard refuses the files for other platforms |
| pnpm's default `node_modules/.pnpm` layout | no: tando does not swap inside it. Build on Linux, or set `node-linker=hoisted` |

## When the deploy stops

- **A nested copy (Next.js and sharp).** Your `package.json` asks for one version of sharp and Next
  asks for another, so npm installs both, one under `node_modules/next/node_modules`. tando
  swaps both. To keep only one copy, use the version Next asks for (`npm ls sharp` shows both).
- **You do not need optimised images.** `images: { unoptimized: true }` in `next.config.*` means
  Next never loads sharp.
- **Anything else, or you want Linux builds.** `tando ci github` writes a GitHub Actions workflow
  that builds on Linux and deploys from there (docs/CI.md).
- **`not verified` in the output.** Commit a lockfile that tando can read (see the table above).
