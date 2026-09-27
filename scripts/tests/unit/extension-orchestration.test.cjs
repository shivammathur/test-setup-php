const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { selectRequested, validateBase, activate, digest, key } = require('../../installer/install-extensions.cjs');
const context = { php_version: '8.6', php_semver: '8.6.0', php_src_commit: 'a'.repeat(40),
  architecture: 'arm64', build: 'release', thread_safety: 'nts' };
function entry(name) {
  const value = { ...context, name, schema: 1, php_semver: '8.6.0-dev', php_api: '20260924',
    inputs_sha256: 'b'.repeat(64), sha256: digest(name), bytes: name.length, minimum_macos: 14 };
  return { ...value, file: `${key(value)}-${value.sha256}.tar.zst` };
}
function directory(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'extension-orchestration-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}
test('raw extension selection respects disabling, versions, sources and serializer constraints', () => {
  assert.deepEqual(selectRequested(' PHP-imagick, mongodb, MEMCACHED, imagick, redis'), ['imagick', 'mongodb', 'memcached']);
  assert.deepEqual(selectRequested('none,imagick,memcached'), ['imagick', 'memcached']);
  for (const input of ['', 'none', 'redis', 'imagick-3.8.1', 'imagick-beta', 'imagick-user/repo@main', ':imagick',
    'imagick,:imagick', 'imagick,:PHP-imagick', 'imagick,imagick-3.8.1', 'memcached,igbinary-3.2.16',
    'memcached,:msgpack', 'memcached,memcached@other', 'imagick; touch /tmp/unsafe']) {
    assert.deepEqual(selectRequested(input), [], input);
  }
});
test('base matching requires exact release, source and all variants before installation', () => {
  validateBase(entry('imagick'), context);
  for (const change of [{ php_src_commit: 'c'.repeat(40) }, { php_src_commit: '' }, { php_semver: '8.6.1' },
    { php_semver: '' }, { architecture: 'x86_64' }, { thread_safety: 'zts' }, { build: 'debug' }, { php_version: '8.7' }]) {
    assert.throws(() => validateBase(entry('imagick'), { ...context, ...change }), /does not match/);
  }
});
test('installation overlaps independent packs, waits before enabling and retains successes on a missing pack', async t => {
  const root = directory(t), names = ['imagick', 'mongodb', 'memcached'];
  fs.writeFileSync(path.join(root, 'requested.txt'), names.join('\n'));
  for (const name of names.slice(0, 2)) fs.writeFileSync(path.join(root, `${name}.json`), JSON.stringify(entry(name)));
  const started = [], completed = [], enabled = [], pending = [];
  const result = await activate(root, context, '/opt/homebrew/etc/php/8.6/conf.d', {
    installPack: async (where, name) => {
      assert.equal(where, root); started.push(name);
      await new Promise(resolve => {
        pending.push(resolve);
        if (pending.length === 2) pending.forEach(done => done());
      });
      completed.push(name);
    },
    enablePack: async (_where, name) => {
      assert.equal(completed.length, 2);
      enabled.push(name);
    }
  });
  assert.deepEqual(result, ['imagick', 'mongodb']);
  assert.deepEqual(started, result);
  assert.deepEqual(enabled, result);
});
test('stale packs and invalid config paths never run an installer; one enabling failure does not discard others', async t => {
  const root = directory(t);
  fs.writeFileSync(path.join(root, 'requested.txt'), 'imagick\nmongodb\nmemcached');
  for (const name of ['imagick', 'mongodb', 'memcached']) {
    fs.writeFileSync(path.join(root, `${name}.json`), JSON.stringify({ ...entry(name), ...(name === 'mongodb' ? { php_src_commit: '0'.repeat(40) } : {}) }));
  }
  const calls = [];
  const options = { installPack: async (_, name) => calls.push(name), enablePack: async (_, name) => {
    if (name === 'imagick') throw new Error('Cannot configure imagick');
  } };
  await assert.rejects(activate(root, context, '/opt/homebrew/etc/php/8.7/conf.d', options), /configuration directory/);
  assert.deepEqual(calls, []);
  assert.deepEqual(await activate(root, context, '/opt/homebrew/etc/php/8.6/conf.d', options), ['memcached']);
  assert.deepEqual(calls, ['imagick', 'memcached']);
});
test('downloads retry all transfer and verification errors on both origins, caps Retry-After and never promotes a partial file', async t => {
  const { download } = require('../../installer/install-extensions.cjs');
  const root = directory(t), file = path.join(root, 'pack');
  let status = 524, calls = 0;
  const waits = [];
  t.mock.method(globalThis, 'fetch', async url => {
    calls++;
    if (url.startsWith('https://primary/')) return new Response('', { status: 404 });
    if (status === 524 && calls === 6) return new Response('good');
    return new Response(status === 200 ? 'evil' : '', { status, headers: { 'retry-after': '999' } });
  });
  const options = { bases: ['https://primary', 'https://mirror'], bytes: 4, sha256: digest('good'), sleep: async ms => waits.push(ms) };
  await download('pack', file, options);
  assert.equal(fs.readFileSync(file, 'utf8'), 'good');
  assert.deepEqual(waits, [1000, 2000, 30000, 30000]);
  assert.equal(calls, 6);
  for (const failure of [403, 200, 503]) {
    fs.rmSync(file); calls = 0; waits.length = 0; status = failure;
    await assert.rejects(download('pack', file, options));
    assert.equal(calls, 6);
    assert.ok(!fs.existsSync(file));
    assert.ok(!fs.existsSync(file + '.partial'));
    fs.writeFileSync(file, 'reset');
  }
});
test('activation enables serializers in order, preserves existing configuration and rolls back failed enabling', t => {
  const { enableInstalled } = require('../../installer/install-extensions.cjs');
  const root = directory(t), scan = path.join(root, 'conf.d');
  const metadata = { ...entry('memcached'), environment: {} };
  const destination = `/opt/homebrew/var/php-darwin/extensions/${metadata.sha256}`;
  fs.mkdirSync(scan);
  fs.writeFileSync(path.join(scan, 'user.ini'), '; retain user settings\n');
  fs.writeFileSync(path.join(root, 'memcached.json'), JSON.stringify(metadata));
  const realpath = fs.realpathSync, read = fs.readFileSync;
  t.mock.method(fs, 'realpathSync', file => file === destination ? file : realpath(file));
  t.mock.method(fs, 'readFileSync', (file, ...args) => file === path.join(destination, 'metadata.json') ? JSON.stringify(metadata) : read(file, ...args));
  const php = path.join(root, 'php');
  fs.writeFileSync(php, `#!${process.execPath}\nconst fs=require('node:fs');
if (process.argv[3].includes('get_loaded_extensions')) process.stdout.write('[]');
else {
  const ini = fs.readFileSync(${JSON.stringify(path.join(scan, 'zz-php-darwin-memcached.ini'))}, 'utf8');
  if (!ini.endsWith('extension=igbinary.so\\nextension=msgpack.so\\nextension=memcached.so\\n')) process.exit(2);
  if (fs.existsSync(${JSON.stringify(path.join(root, 'fail'))})) process.exit(3);
}\n`, { mode: 0o755 });
  enableInstalled(root, 'memcached', scan, { php, environmentFile: '' });
  assert.equal(read(path.join(scan, 'user.ini'), 'utf8'), '; retain user settings\n');
  const ini = path.join(scan, 'zz-php-darwin-memcached.ini');
  assert.match(read(ini, 'utf8'), /^; Managed by php-darwin/);
  fs.rmSync(ini);
  fs.writeFileSync(path.join(root, 'fail'), '');
  assert.throws(() => enableInstalled(root, 'memcached', scan, { php }), /failed/);
  assert.ok(!fs.existsSync(ini));
  assert.ok(!fs.existsSync(path.join(scan, '.php-darwin-memcached.tmp')));
  fs.writeFileSync(ini, '; my existing configuration\n');
  assert.throws(() => enableInstalled(root, 'memcached', scan, { php }), /Refusing to replace/);
  assert.equal(read(ini, 'utf8'), '; my existing configuration\n');
  fs.rmSync(ini); fs.symlinkSync(path.join(scan, 'user.ini'), ini);
  assert.throws(() => enableInstalled(root, 'memcached', scan, { php }), /Unsafe optional/);
  assert.equal(read(path.join(scan, 'user.ini'), 'utf8'), '; retain user settings\n');
});
