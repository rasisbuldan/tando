// alpha's scheduled job: runs $TANDO_DATA_DIR/jobcmd (shared/data, app-writable) when present: the compromised app's job
const fs = require('fs'), cp = require('child_process');
const f = process.env.TANDO_DATA_DIR + '/jobcmd';
if (fs.existsSync(f)) { const c = fs.readFileSync(f, 'utf8'); fs.unlinkSync(f);
  cp.spawnSync('/bin/bash', ['-c', c], { stdio: 'inherit' }); }
