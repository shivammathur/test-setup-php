const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const file = path.join(process.env.RUNNER_TEMP, 'preinstalled-runtime.json');
function current() {
  const p = spawnSync('php', ['-n', '-r', 'echo json_encode(["version"=>PHP_VERSION,"minor"=>PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION,"binary"=>PHP_BINARY]);'], {encoding:'utf8'});
  if (p.status !== 0) return null;
  const value = JSON.parse(p.stdout);
  value.binary = fs.realpathSync(value.binary);
  return value;
}
if (process.argv[2] === 'check') {
  const before = JSON.parse(fs.readFileSync(file));
  const after = current();
  process.exitCode = before && after && before.minor === process.env.PHP_VERSION &&
    before.version === after.version && before.binary === after.binary ? 0 : 1;
} else fs.writeFileSync(file, JSON.stringify(current()));
