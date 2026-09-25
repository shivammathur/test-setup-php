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
const started = performance.now();
const log = fs.openSync(path.join(process.env.RUNNER_TEMP, 'direct-installer.log'), 'w');
const result = spawnSync('bash', [file, version, 'release', 'nts', '', process.env.INPUT_EXTENSIONS], {stdio:['ignore',log,log]});
fs.closeSync(log);
process.stdout.write(fs.readFileSync(path.join(process.env.RUNNER_TEMP, 'direct-installer.log')));
fs.writeFileSync(path.join(process.env.RUNNER_TEMP, 'base-cache-status.txt'), String(result.status ?? 1));
console.log(JSON.stringify({direct_installer_seconds:(performance.now()-started)/1000,status:result.status}));
process.exitCode = result.status ?? 1;
