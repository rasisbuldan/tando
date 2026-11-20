# Frameworks: what tando does with each

`tando init` (and a bare `tando up`, which runs it) reads the project's files, never the network,
and writes tando.conf. It prints one line that says what it found and why:

    tando: detected: NestJS (@nestjs/core in package.json, package-lock.json), build: npm run build, start: node dist/main, output: .

The first row that matches wins. Anything it does not know gets the generic Node path (a
package.json) or the static path (an index.html), as before. Every setting can be changed in
tando.conf afterwards (`tando help conf`). The fixtures in test/fixtures/apps are checked by
test/detect-test.sh; the ones marked e2e are deployed by test/e2e-frameworks.sh.

| Framework | Detected by | recipe | build | start | output | You may need to set |
|---|---|---|---|---|---|---|
| Next.js 14, 15, 16 (app and pages router) | `next` in package.json | `next` | `npm run build` | `node server.js` | `.next/standalone` | `output: "standalone"` in next.config (`tando up --yes` adds it). `basePath` becomes `path`. |
| Nuxt | `nuxt` | `node` | `npm run build` | `node server/index.mjs` | `.output` | |
| SvelteKit (e2e) | `@sveltejs/adapter-node` | `node` | `npm run build` | `node build` | `.` | Without adapter-node: refused with the line to add. |
| Astro SSR | `@astrojs/node` | `node` | `npm run build` | `HOST=127.0.0.1 node dist/server/entry.mjs` | `.` | |
| React Router 7 / Remix | `@react-router/serve`, `@remix-run/serve` | `node` | `npm run build` | `npm start` | `.` | |
| NestJS (e2e) | `@nestjs/core` | `node` | `npm run build` (`nest build`) | `node dist/main` (or the `start:prod` script when it is `node ...`) | `.` | |
| Astro static | `astro` | `static` | `npm run build` | none | `dist` | |
| Vite + Vue, React, Svelte (Vue: e2e) | `vite` and no server entry file | `static` | `npm run build` | none | `dist`, or `build.outDir` of vite.config | `spa = true` is written when a router is a dependency (vue-router, react-router, react-router-dom, @tanstack/react-router, svelte-routing, @solidjs/router). |
| Express, Fastify, Koa, Hono, hapi, plain Node (Express with pnpm: e2e) | package.json, or server.js, index.js, app.js, main.js | `node` | `npm run build` when there is a build script | the `start` script when it is `node <file>`, else the entry file, `main`, or `npm start` | `.` | Listen on `process.env.PORT`: a fixed port is pointed out. |
| Django | manage.py and `<project>/wsgi.py` | `python` | | `gunicorn -b 127.0.0.1:$PORT <project>.wsgi` | `.` | `ALLOWED_HOSTS`; `release = python manage.py collectstatic --noinput` with `STATIC_ROOT`. |
| FastAPI | `fastapi` in requirements or `FastAPI(` | `python` | | `uvicorn <module>:<app> --host 127.0.0.1 --port $PORT` | `.` | |
| Flask | `flask` in requirements or `Flask(` | `python` | | `gunicorn -b 127.0.0.1:$PORT <module>:<app>` | `.` | |
| Dockerfile | Dockerfile | `container` | the image | the image | | `container_port` (from `EXPOSE`). |
| Static HTML | index.html in dist, public, build or . | `static` | | none | that directory | |

Dependencies: tando ships the project's `node_modules` as it is on your machine (platform packages
are swapped for the server's). When it is missing, `tando up` installs it with the package manager
of the lockfile: `pnpm install --frozen-lockfile` (pnpm-lock.yaml), `yarn install --immutable`
(yarn.lock with .yarnrc.yml, Yarn 2+), `yarn install --frozen-lockfile` (Yarn 1), `bun install`,
`npm ci` (package-lock.json) or `npm install`. pnpm and Yarn 2+ run through corepack when the
command is not installed. Yarn Plug'n'Play has no node_modules: add `nodeLinker: node-modules` to
.yarnrc.yml.

Node version: `node =` in tando.conf, else `.nvmrc`, `.node-version` or `engines.node` in
package.json (the major); a server that runs another Node gets a note on every deploy.

Not supported yet: deploying one package of a monorepo, from the workspace root or from inside the
package (refused at once: its dependencies are linked into the root's `node_modules`; make a
standalone copy with `pnpm deploy --filter <package> <dir>` and deploy that directory); Next.js without standalone
output (refused before anything is installed: the standalone release of a small app is 56 MB and
1,900 files, `next start` with all of node_modules 360 MB and 9,000 files).
