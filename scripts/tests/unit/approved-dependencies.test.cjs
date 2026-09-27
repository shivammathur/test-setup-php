const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {createHash} = require('node:crypto');
const {ApprovedDependencies, validatePlatform} = require('../../cache/approved-dependencies.cjs');
const {roots, merge} = require('../../cache/update-dependencies.cjs');
const hash = data => createHash('sha256').update(data).digest('hex');

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'approved-dependencies-'));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  const bytes = Buffer.from('verified upstream bottle');
  const bottle = {formula: 'jq', version: '1.8.2', tag: 'all', sha256: hash(bytes),
    url: `https://ghcr.io/v2/homebrew/core/jq/blobs/sha256:${hash(bytes)}`};
  const platform = {macos: 14, prefix: '/opt/homebrew', packages: {jq: {version: '1.8.2', bottle}}};
  return {directory, bytes, bottle, platform};
}

test('approved upstream bottles use mirror bytes, retain dependency flags and reuse verified local files', async t => {
  const f = fixture(t), downloads = [], commands = [];
  const approved = new ApprovedDependencies({platforms: {arm64: f.platform}}, {
    download: async (url, file) => {downloads.push(url); fs.writeFileSync(file, f.bytes); return 200;},
  });
  const item = {full_name: 'jq', name: 'jq', version: '1.8.2'};
  approved.validatePlan([item], {arch: 'arm64', macos: '14', prefix: '/opt/homebrew'});
  const options = {cacheRoot: f.directory, flags: ['--as-dependency'], run: (...args) => commands.push(args)};
  assert.equal((await approved.restore(item, options)).source, false);
  await approved.restore(item, options);
  assert.equal(downloads.length, 1);
  assert.ok(downloads[0].startsWith('https://artifacts.php-darwin.setup-php.com/'));
  assert.equal(commands.length, 2);
  assert.ok(commands[0][1].includes('--as-dependency'));
  assert.ok(commands[0][1].includes('--force-bottle'));
});

test('missing or corrupt mirror data falls back to the exact approved upstream checksum', async t => {
  const f = fixture(t);
  for (const failure of ['missing', 'corrupt']) {
    const urls = [];
    const approved = new ApprovedDependencies({platforms: {arm64: f.platform}}, {
      download: async (url, file, options) => {
        urls.push(url);
        if (url === f.bottle.url) {assert.equal(options.upstream, true); fs.writeFileSync(file, f.bytes); return 200;}
        fs.writeFileSync(file, 'corrupt');
        return failure === 'missing' ? 404 : 200;
      },
    });
    const item = {full_name: 'jq', version: '1.8.2'};
    approved.validatePlan([item], {arch: 'arm64', macos: '14', prefix: '/opt/homebrew'});
    await approved.restore(item, {cacheRoot: path.join(f.directory, failure), flags: [], run() {}});
    assert.equal(urls.length, 2);
    assert.equal(urls[1], f.bottle.url);
  }
});

test('missing approvals and newer patches fail before any dependency is installed', t => {
  const f = fixture(t), approved = new ApprovedDependencies({platforms: {arm64: f.platform}});
  const env = {arch: 'arm64', macos: '14', prefix: '/opt/homebrew'};
  assert.throws(() => approved.validatePlan([{full_name: 'gcc', version: '16.2.0'}], env), /not in the approved snapshot/);
  assert.throws(() => approved.validatePlan([{full_name: 'shivammathur/php/bison@2.7', version: '2.7.1'}], env), /not in the approved snapshot/);
  assert.throws(() => approved.validatePlan([{full_name: 'jq', version: '1.8.3', installed: true}], env), /not in the approved snapshot/);
  assert.throws(() => approved.validatePlan([], {...env, arch: 'x86_64'}), /not been prepared/);
  assert.throws(() => validatePlatform({...f.platform, packages: {jq: {version: '1.8.3', bottle: f.bottle}}}, 'arm64'), /identity differs/);
});

test('a newer preinstalled dependency is removed only after its approved replacement is verified', async t => {
  const f = fixture(t), commands = [];
  const approved = new ApprovedDependencies({platforms: {arm64: f.platform}}, {
    download: async (url, file) => {fs.writeFileSync(file, f.bytes); return 200;},
  });
  const item = {full_name: 'jq', version: '1.8.2', installed_versions: ['1.8.3']};
  approved.validatePlan([item], {arch: 'arm64', macos: '14', prefix: '/opt/homebrew'});
  await approved.prefetch([item], {cacheRoot: f.directory});
  await approved.restore(item, {cacheRoot: f.directory, flags: [], run: (program, args) => commands.push(args)});
  assert.deepEqual(commands[0], ['uninstall', '--formula', '--force', '--ignore-dependencies', 'jq']);
  assert.equal(commands[1][0], 'install');
  assert.ok(commands[1].includes('--force-bottle'));
});

test('dependency roots cover every PHP variant, coverage extension and optional-pack member', () => {
  const items = roots();
  assert.equal(items.length, new Set(items).size);
  for (const formula of ['jq', 'zstd', 'shivammathur/php/php@5.6-debug-zts', 'shivammathur/php/php@8.7',
    'shivammathur/extensions/xdebug@5.6', 'shivammathur/extensions/pcov@8.5',
    'shivammathur/extensions/igbinary@5.6', 'shivammathur/extensions/msgpack@8.7', 'shivammathur/extensions/imagick@8.5']) {
    assert.ok(items.includes(formula), formula);
  }
  assert.ok(!items.includes('shivammathur/extensions/pcov@5.6'));
});

test('promotion input requires matching native proofs and a common snapshot for both architectures', t => {
  const f = fixture(t), output = path.join(f.directory, 'merged.json');
  for (const arch of ['arm64', 'x86_64']) {
    const candidate = {schema: 1, core_commit: 'a'.repeat(40), platforms: {
      [arch]: {...f.platform, macos: arch === 'arm64' ? 14 : 15, prefix: arch === 'arm64' ? '/opt/homebrew' : '/usr/local'},
    }};
    const data = JSON.stringify(candidate);
    fs.writeFileSync(path.join(f.directory, `dependencies-${arch}.json`), data);
    fs.writeFileSync(path.join(f.directory, `dependency-verification-${arch}.json`), JSON.stringify({
      schema: 1, arch, core_commit: candidate.core_commit, sha256: hash(data), dependencies: 1,
      cold_source_builds: 0, hot_source_builds: 0,
    }));
  }
  merge(f.directory, output);
  assert.deepEqual(Object.keys(JSON.parse(fs.readFileSync(output)).platforms), ['arm64', 'x86_64']);
  const file = path.join(f.directory, 'dependencies-x86_64.json');
  fs.appendFileSync(file, '\n');
  assert.throws(() => merge(f.directory, output), /mismatched native/);
});
