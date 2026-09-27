const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

test('preservation checks ignore empty racks, retain existing PHP, and detect changed services', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'php-preservation-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const prefix = path.join(root, 'brew'), services = path.join(root, 'LaunchAgents');
  const binary = path.join(prefix, 'Cellar/php@8.4/8.4.25/bin/php');
  fs.mkdirSync(path.dirname(binary), { recursive: true });
  const config = path.join(path.dirname(binary), 'php-config');
  const smoke = `#!/bin/sh\n[ "$1" = -n ] && [ "$2" = -r ] && [ "$3" = 'exit(0);' ]\n`;
  fs.writeFileSync(binary, smoke, {mode: 0o755});
  fs.writeFileSync(config, '#!/bin/sh\nprintf 8.4.25\n', {mode: 0o755});
  fs.mkdirSync(path.join(prefix, 'Cellar/php@8.2'), { recursive: true });
  fs.mkdirSync(services);
  const service = path.join(services, 'homebrew.mxcl.php@8.4.plist');
  fs.writeFileSync(service, 'existing service');
  const run = mode => spawnSync('bash', [path.join(__dirname, '../helpers/check-preserved-homebrew.sh'),
    mode, prefix, path.join(root, 'state.json'), services], { encoding: 'utf8' });
  assert.equal(run('snapshot').status, 0);
  fs.rmdirSync(path.join(prefix, 'Cellar/php@8.2'));
  assert.equal(run('check').status, 0);
  fs.writeFileSync(service, 'changed service');
  assert.match(run('check').stderr, /service definitions changed/);
  fs.writeFileSync(service, 'existing service');
  fs.writeFileSync(config, '#!/bin/sh\nprintf 8.4.26\n');
  assert.match(run('check').stderr, /Existing PHP runtime changed or stopped working/);
  fs.writeFileSync(config, '#!/bin/sh\nprintf 8.4.25\n');
  fs.writeFileSync(binary, '#!/bin/sh\nexit 1\n');
  assert.match(run('check').stderr, /Existing PHP runtime changed or stopped working/);
  fs.writeFileSync(binary, smoke);
  fs.unlinkSync(service);
  assert.match(run('check').stderr, /service definitions changed/);
  fs.writeFileSync(service, 'existing service');
  fs.unlinkSync(binary);
  assert.match(run('check').stderr, /Removed existing PHP kegs/);
});

test('preservation checks detect service retargeting even when plist bytes match', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'php-service-links-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const services = path.join(root, 'LaunchAgents'); fs.mkdirSync(services);
  const first = path.join(root, 'first.plist'), second = path.join(root, 'second.plist');
  fs.writeFileSync(first, 'same service definition'); fs.writeFileSync(second, 'same service definition');
  const service = path.join(services, 'homebrew.mxcl.php@7.0-debug.plist');
  fs.symlinkSync(first, service);
  const run = mode => spawnSync('bash', [path.join(__dirname, '../helpers/check-preserved-homebrew.sh'),
    mode, path.join(root, 'brew'), path.join(root, 'state.json'), services], { encoding: 'utf8' });
  assert.equal(run('snapshot').status, 0);
  assert.equal(run('check').status, 0);
  fs.unlinkSync(service); fs.symlinkSync(second, service);
  assert.match(run('check').stderr, /service definitions changed/);
});
