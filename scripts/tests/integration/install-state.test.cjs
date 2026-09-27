const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {test} = require('node:test');

function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'php-darwin-state-')));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const prefix = path.join(root, 'prefix');
  const file = (relative, data = '') => {
    const target = path.join(root, relative); fs.mkdirSync(path.dirname(target), {recursive: true});
    fs.writeFileSync(target, data); return target;
  };
  const link = (relative, target) => {
    const name = path.join(prefix, relative); fs.mkdirSync(path.dirname(name), {recursive: true}); fs.symlinkSync(target, name);
  };
  const packages = file('packages', 'php@8.6\t../Cellar/php@8.6/8.6.0\tfalse\nlibxml2\t../Cellar/libxml2/2.15\tfalse\nopenssl@3\t../Cellar/openssl@3/3.6\ttrue\n');
  const existing = file('existing', 'Cellar/libxml2/2.14\nCellar/openssl@3/3.6\n');
  const changed = file('changed'); const linked = file('linked'); const journal = file('journal');
  const run = mode => spawnSync('bash', [path.join(__dirname, '../../installer/install-state.sh'), mode, prefix, packages,
    mode === 'plan' ? existing : changed, mode === 'plan' ? changed : journal, linked], {encoding: 'utf8'});
  const php = file('prefix/Cellar/php@8.6/8.6.0/bin/php', '#!/usr/bin/env bash\nprintf "called\\n" >> "$PROBE_LOG"\nexit "${PROBE_STATUS:-0}"\n');
  fs.chmodSync(php, 0o755);
  const config = file('prefix/Cellar/php@8.6/8.6.0/bin/php-config', '#!/bin/sh\nversion="8.6.0-dev"\necho DO_NOT_EXECUTE\n');
  link('opt/php@8.6', '../Cellar/php@8.6/8.6.0');
  const module = file('prefix/lib/php/pecl/20260914/xdebug.so', 'module fixture');
  const extensions = file('extensions', 'xdebug\tzend_extension\tlib/php/pecl/20260914/xdebug.so\n');
  const probe = path.join(root, 'php-calls');
  const verify = (env = {}) => spawnSync('bash', [path.join(__dirname, '../../installer/verify-runtime.sh'), prefix, 'php@8.6', '8.6.0-dev', extensions],
    {encoding: 'utf8', env: {...process.env, PHP_DARWIN_VERIFY_RUNTIME: 'false', PROBE_LOG: probe, ...env}});
  return {root, prefix, file, link, packages, existing, changed, linked, journal, run, php, config, module, extensions, probe, verify};
}

test('package planning reuses exact kegs and only unlinks linked changed non-keg-only dependencies', t => {
  const f = fixture(t);
  f.link('var/homebrew/linked/libxml2', '../../../Cellar/libxml2/2.14');
  const result = f.run('plan'); assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(f.changed, 'utf8'), 'php@8.6\nlibxml2\n');
  assert.equal(fs.readFileSync(f.linked, 'utf8'), 'libxml2\n');
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'var/homebrew/linked/libxml2')), '../../../Cellar/libxml2/2.14');
});

test('opt updates journal old targets and leave reused packages unchanged', t => {
  const f = fixture(t);
  f.file('prefix/Cellar/libxml2/2.15/INSTALL_RECEIPT.json', '{}');
  f.file('prefix/Cellar/openssl@3/3.6/INSTALL_RECEIPT.json', '{}');
  f.link('opt/libxml2', '../Cellar/libxml2/2.14');
  f.link('opt/openssl@3', '../Cellar/openssl@3/3.5');
  assert.equal(f.run('plan').status, 0);
  const result = f.run('receipts'); assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'opt/libxml2')), '../Cellar/libxml2/2.15');
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'opt/openssl@3')), '../Cellar/openssl@3/3.5');
  assert.equal(fs.readFileSync(f.journal, 'utf8'), 'libxml2\t../Cellar/libxml2/2.14\n');
});

test('invalid or missing later packages fail before any opt mutation', t => {
  const f = fixture(t);
  f.file('prefix/Cellar/libxml2/2.15/file');
  f.link('opt/libxml2', '../Cellar/libxml2/2.14');
  assert.equal(f.run('plan').status, 0);
  assert.equal(f.run('receipts').status, 1);
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'opt/libxml2')), '../Cellar/libxml2/2.14');
  assert.equal(fs.readFileSync(f.journal, 'utf8'), '');
  f.file('prefix/Cellar/openssl@3/3.6/file');
  fs.unlinkSync(path.join(f.prefix, 'opt/libxml2'));
  f.file('prefix/opt/libxml2', 'user file');
  assert.equal(f.run('receipts').status, 1);
  assert.equal(fs.readFileSync(path.join(f.prefix, 'opt/libxml2'), 'utf8'), 'user file');
});

test('planning rejects escaping dependency records and targets', t => {
  const f = fixture(t);
  f.link('var/homebrew/linked/libxml2', '../../../Cellar/other/2.14');
  assert.equal(f.run('plan').status, 1);
  for (const entry of ['../escape\t../Cellar/../escape/1\tfalse\n', 'libxml2\t../Cellar/libxml2/..\tfalse\n']) {
    fs.writeFileSync(f.packages, entry); assert.equal(f.run('plan').status, 1);
  }
});

test('version comes from php-config and one smoke process checks the runtime', t => {
  const f = fixture(t); const result = f.verify();
  assert.equal(result.status, 0, result.stderr); assert.equal(result.stdout, '');
  assert.equal(fs.readFileSync(f.probe, 'utf8'), 'called\n');
});

test('default smoke test rejects a broken reused dependency', t => {
  const f = fixture(t); const result = f.verify({PROBE_STATUS: '127'});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /runtime smoke test failed/);
});

test('wrong, missing, duplicate and executable version assignments are rejected without evaluation', t => {
  const f = fixture(t);
  for (const value of ['version="8.5.0"\n', '# version="8.6.0-dev"\n', 'version="8.6.0-dev"\nversion="8.6.0-dev"\n', 'version="$(touch '+f.probe+')"\n']) {
    fs.writeFileSync(f.config, value); assert.equal(f.verify().status, 1);
    assert.equal(fs.existsSync(f.probe), false);
  }
});

test('missing, empty or symlinked cached modules are rejected', t => {
  const f = fixture(t);
  fs.unlinkSync(f.module); assert.equal(f.verify().status, 1);
  fs.writeFileSync(f.module, ''); assert.equal(f.verify().status, 1);
  fs.unlinkSync(f.module); fs.symlinkSync(f.config, f.module); assert.equal(f.verify().status, 1);
});

test('diagnostic mode still executes PHP and extensions and rejects runtime failure', t => {
  const f = fixture(t);
  let result = f.verify({PHP_DARWIN_VERIFY_RUNTIME: 'true'}); assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(f.probe, 'utf8'), 'called\ncalled\n');
  result = f.verify({PHP_DARWIN_VERIFY_RUNTIME: 'true', PROBE_STATUS: '1'}); assert.equal(result.status, 1);
});
