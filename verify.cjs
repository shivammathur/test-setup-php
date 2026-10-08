const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { command, digest, download, runtimeContext, key, validateEntry } = require('./php-darwin/scripts/installer/install-extensions.cjs');
const { dependencies } = require('./php-darwin/scripts/build/extension-pack.cjs');

(async () => {
  const phase = process.argv[2];
  assert.ok(['cold', 'hot'].includes(phase));
  const actual = runtimeContext();
  const expected = { name: 'swoole', php_version: process.env.PHP_VERSION,
    build: process.env.BUILD, thread_safety: process.env.TS,
    architecture: process.arch === 'arm64' ? 'arm64' : 'x86_64' };
  for (const field of ['php_version', 'build', 'thread_safety', 'architecture']) assert.equal(actual[field], expected[field], field);
  const php = command('which', ['php']);
  const runtime = JSON.parse(command(php, ['-r', 'echo json_encode(array("zts" => PHP_ZTS, "debug" => PHP_DEBUG));']));
  assert.equal(Boolean(runtime.zts), expected.thread_safety === 'zts');
  assert.equal(Boolean(runtime.debug), expected.build === 'debug');
  const prefix = command('brew', ['--prefix']);
  const manifestFile = path.resolve('diagnostics/extensions-manifest.json');
  await download(`extensions-${actual.php_version}-manifest.json`, manifestFile);
  const manifest = JSON.parse(fs.readFileSync(manifestFile));
  assert.equal(manifest.schema, 1);
  const entries = manifest.assets.filter(entry => key(entry) === key(expected));
  assert.equal(entries.length, 1);
  const entry = validateEntry(entries[0]);
  assert.equal(entry.php_api, actual.php_api);
  assert.equal(entry.php_semver, command('php-config', ['--version']));
  const module = path.join(actual.extension_dir, 'swoole.so');
  assert.ok(fs.lstatSync(module).isSymbolicLink(), 'Swoole must come from the optional cache');
  const destination = path.join(prefix, 'var/php-darwin/extensions', entry.sha256);
  assert.equal(fs.realpathSync(module), path.join(destination, 'modules/swoole.so'));
  const metadata = JSON.parse(fs.readFileSync(path.join(destination, 'metadata.json')));
  assert.equal(key(metadata), key(entry));
  assert.equal(metadata.inputs_sha256, entry.inputs_sha256);
  assert.deepEqual(metadata.modules, ['swoole']);
  assert.ok(fs.readdirSync(path.join(destination, 'licenses/swoole')).length);
  const linkage = dependencies(module);
  for (const reference of linkage) assert.ok(reference.startsWith('@loader_path/') ||
    reference.startsWith('/usr/lib/') || reference.startsWith('/System/Library/'), reference);
  const smoke = spawnSync(php, ['php-darwin/scripts/tests/helpers/swoole-smoke.php'], { encoding: 'utf8', timeout: 30000 });
  assert.equal(smoke.status, 0, smoke.stderr || smoke.stdout);
  assert.equal(smoke.stderr, '', 'Swoole must load without PHP startup warnings');
  assert.match(smoke.stdout, /Swoole shared table passed/);
  const started = Number(fs.readFileSync(path.join(process.env.RUNNER_TEMP, 'php-darwin-e2e-started-at.txt')));
  assert.ok(Number.isSafeInteger(started) && started > 0);
  const installed = JSON.parse(command('brew', ['info', '--installed', '--json=v2']));
  const built = installed.formulae.flatMap(formula => formula.installed
    .filter(item => item.time >= started && item.poured_from_bottle !== true).map(() => formula.full_name));
  assert.deepEqual(built, [], 'setup-php must not compile PHP, Swoole or dependencies');
  const suffix = (expected.build === 'debug' ? '-debug' : '') + (expected.thread_safety === 'zts' ? '-zts' : '');
  const scan = path.join(prefix, 'etc/php', actual.php_version + suffix, 'conf.d');
  assert.ok(fs.existsSync(path.join(scan, '20-swoole.ini')));
  const phpManifestFile = path.resolve('diagnostics/php-manifest.json');
  await download(`php-${actual.php_version}-manifest.json`, phpManifestFile, { bases: [
    `https://github.com/shivammathur/php-darwin/releases/download/php-${actual.php_version}`,
    `https://artifacts.php-darwin.setup-php.com/php-${actual.php_version}`,
  ] });
  const phpManifest = JSON.parse(fs.readFileSync(phpManifestFile));
  assert.equal(phpManifest.php_semver, entry.php_semver);
  const tap = command('brew', ['--repository', 'shivammathur/php']);
  assert.equal(command('git', ['-C', tap, 'rev-parse', 'HEAD']), phpManifest.homebrew_php_commit);
  assert.equal(command('git', ['-C', tap, 'config', '--get', 'php-darwin.snapshot-commit']), phpManifest.homebrew_php_commit);
  command('bash', ['php-darwin/scripts/tests/helpers/check-preserved-homebrew.sh', 'check', prefix,
    path.join(process.env.RUNNER_TEMP, 'php-darwin-e2e-preserved.json'),
    path.join(process.env.HOME, 'Library/LaunchAgents'), '/Library/LaunchAgents', '/Library/LaunchDaemons']);
  const report = { ...expected, phase, php_semver: entry.php_semver, php_api: actual.php_api,
    archive: entry.file, archive_sha256: entry.sha256, archive_bytes: entry.bytes,
    php_sha256: digest(fs.readFileSync(fs.realpathSync(php))),
    module_sha256: digest(fs.readFileSync(module)), linkage, smoke: smoke.stdout.trim(), source_builds: built };
  if (phase === 'hot') {
    const cold = JSON.parse(fs.readFileSync('diagnostics/cold.json'));
    for (const field of ['archive_sha256', 'php_sha256', 'module_sha256']) assert.equal(report[field], cold[field], field);
  }
  fs.writeFileSync(`diagnostics/${phase}.json`, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report, null, 2));
})().catch(error => { console.error(error); process.exitCode = 1; });
