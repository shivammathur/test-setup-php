const fs = require('node:fs');

function recordMetric(event) {
  if (!process.env.PHP_DARWIN_METRICS) return;
  fs.appendFileSync(process.env.PHP_DARWIN_METRICS, JSON.stringify({
    at: new Date().toISOString(), php: process.env.PHP_VERSION,
    arch: process.env.ARCH, build: process.env.BUILD, ts: process.env.TS, ...event,
    run: process.env.GITHUB_RUN_ID, attempt: process.env.GITHUB_RUN_ATTEMPT,
  }) + '\n');
}

module.exports = { recordMetric };
