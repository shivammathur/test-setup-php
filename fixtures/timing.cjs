const fs = require('node:fs');
const path = require('node:path');
const marker = path.join(process.env.RUNNER_TEMP, 'phpstan-setup-start-ms.txt');
fs.mkdirSync('artifacts', {recursive: true});
if (process.argv[2] === 'start') {
  fs.writeFileSync(marker, String(Date.now()));
} else {
  const finished = Date.now();
  const started = Number(fs.readFileSync(marker, 'utf8'));
  const result = {
    method: process.env.BENCHMARK_METHOD,
    trial: Number(process.env.BENCHMARK_TRIAL),
    os: process.env.RUNNER_OS,
    architecture: process.env.RUNNER_ARCH,
    image: process.env.ImageOS,
    imageVersion: process.env.ImageVersion,
    startedAt: new Date(started).toISOString(),
    finishedAt: new Date(finished).toISOString(),
    elapsedSeconds: (finished - started) / 1000,
  };
  fs.writeFileSync('artifacts/timing.json', JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
}
