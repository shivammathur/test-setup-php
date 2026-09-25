const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const version = process.env.PHP_VERSION;
const before = JSON.parse(fs.readFileSync(path.join(process.env.RUNNER_TEMP, 'preinstalled-runtime.json')));
const direct = process.env.RUNNER_ENVIRONMENT === 'self-hosted' || before?.minor === version;
fs.writeFileSync(path.join(process.env.RUNNER_TEMP, 'installer-mode.json'), JSON.stringify({mode:direct?'direct-before-action':'action', raw_extensions:process.env.INPUT_EXTENSIONS}));
if (!direct) process.exit(0);
const file = path.join(process.env.RUNNER_TEMP, 'published-install.sh');
const fetch = spawnSync('bash', ['-c', `
source php-cache/scripts/lib/lib.sh
url="https://github.com/shivammathur/php-darwin/releases/download/php-$PHP_VERSION/install.sh"
status=$(php_darwin_request_release "$url" "$RUNNER_TEMP/published-install.sh") || status=000
if [ "$status" != 200 ]; then
  status=$(php_darwin_request_release "https://artifacts.php-darwin.setup-php.com/php-$PHP_VERSION/install.sh" "$RUNNER_TEMP/published-install.sh") || status=000
fi
[ "$status" = 200 ]
`], {stdio:'inherit'});
if (fetch.status !== 0) process.exit(fetch.status || 1);
const expected = require('./expected-installers.json')[version];
require('node:assert/strict').equal(crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'), expected);
// The standalone installer requires Node on PATH for optional packs. Reuse the
// runtime executing this fixture; do not install Node or alter the runner.
const installerEnv = {...process.env, PATH: path.dirname(process.execPath) + path.delimiter + (process.env.PATH || '')};
const nodeProbe = spawnSync('bash', ['-c', 'command -v node'], {env: installerEnv, encoding: 'utf8'});
require('node:assert/strict').equal(nodeProbe.status, 0);
require('node:assert/strict').equal(fs.realpathSync(nodeProbe.stdout.trim()), fs.realpathSync(process.execPath));
fs.writeFileSync(path.join(process.env.RUNNER_TEMP, 'installer-runtime.json'), JSON.stringify({
  node: nodeProbe.stdout.trim(), expected_node: process.execPath, version: process.version
}));
const started = performance.now();
const log = fs.openSync(path.join(process.env.RUNNER_TEMP, 'direct-installer.log'), 'w');
const result = spawnSync('bash', [file, version, 'release', 'nts', '', process.env.INPUT_EXTENSIONS], {env: installerEnv, stdio:['ignore',log,log]});
fs.closeSync(log);
process.stdout.write(fs.readFileSync(path.join(process.env.RUNNER_TEMP, 'direct-installer.log')));
fs.writeFileSync(path.join(process.env.RUNNER_TEMP, 'base-cache-status.txt'), String(result.status ?? 1));
if (result.status === 0) {
  // Stop before setup-php's fallback can build missing packs on persistent hosts.
  const {execFileSync} = require('node:child_process');
  const assert = require('node:assert/strict');
  const prefix = execFileSync('brew', ['--prefix'], {encoding:'utf8'}).trim();
  const extDir = execFileSync('php-config', ['--extension-dir'], {encoding:'utf8'}).trim();
  const runtime = execFileSync('php', ['-n', '-r', 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;'], {encoding:'utf8'}).trim();
  assert.equal(runtime, version);
  const packs = require('./expected-packs.json');
  for (const name of ['imagick', 'mongodb', 'memcached']) {
    const pack = packs.find(e => e.name === name && e.php_version === version && e.architecture === (process.arch === 'arm64' ? 'arm64' : 'x86_64'));
    assert.ok(pack);
    assert.equal(fs.readlinkSync(path.join(extDir, name + '.so')), path.join(prefix, 'var/php-darwin/extensions', pack.sha256, 'modules', name + '.so'));
  }
  console.log('Verified target PHP and all three private packs before setup-php');
}
console.log(JSON.stringify({direct_installer_seconds:(performance.now()-started)/1000,status:result.status}));
process.exitCode = result.status ?? 1;
