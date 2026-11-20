// The fault matrix's worker (test/e2e-matrix.sh --kind worker): runs until it is stopped.
process.on('SIGTERM', () => process.exit(0));
setInterval(() => {}, 1000);
console.log(`mx worker ${process.env.TANDO_WORKER} of release ${process.env.TANDO_RELEASE}`);
