const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { command } = require('../../cache/source-bottle-cache.cjs');
const { checkpointKey, identity, kegDigest, verifyCheckpoint, restoreCheckpoint, stageCheckpoint, pruneCheckpoints, restoreEarly } = require('../../cache/archive-checkpoint.cjs');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'checkpoint-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const inputs = { schema: 1, php: '8.6', arch: 'arm64', build: 'debug', ts: 'zts',
    revision: 'a'.repeat(40), phpCommit: 'b'.repeat(40), extensionsCommit: 'c'.repeat(40), coreCommit: 'd'.repeat(40),
    platform: { compiler: 'clang-1', sdk: '14', macos: '14' }, packages: [{ name: 'libxml2', version: '1', payload: 'abc' }] };
  const item = identity(inputs);
  const builds = path.join(root, 'builds');
  const staged = path.join(root, 'staged');
  fs.mkdirSync(builds);
  const bytes = 'verified native archive fixture';
  fs.writeFileSync(path.join(builds, item.archive), bytes);
  fs.writeFileSync(path.join(builds, item.archive + '.sha256'), crypto.createHash('sha256').update(bytes).digest('hex') + '  ' + item.archive + '\n');
  fs.writeFileSync(path.join(builds, item.metadata), JSON.stringify({ archive: item.archive,
    php_version: inputs.php, architecture: inputs.arch, build: inputs.build, thread_safety: inputs.ts,
    homebrew_php_commit: inputs.phpCommit, homebrew_extensions_commit: inputs.extensionsCommit }));
  stageCheckpoint(inputs, builds, staged);
  const zip = path.join(root, 'artifact.zip');
  command('zip', ['-q', zip, ...item.files], { cwd: staged });
  const data = fs.readFileSync(zip);
  const artifact = { id: 1, name: item.name, digest: 'sha256:' + crypto.createHash('sha256').update(data).digest('hex'),
    workflow_run: { id: 10, head_sha: inputs.revision } };
  const warnings = [];
  const cache = { warn: value => warnings.push(value), api: async (endpoint, options) => {
    if (endpoint.startsWith('actions/artifacts?')) return { artifacts: [artifact] };
    return options.consume(new Response(data));
  } };
  return { root, inputs, item, builds, staged, zip, artifact, warnings, cache };
}

test('early reuse restores only this run with identical pinned sources and toolchain', async t => {
  const f = fixture(t), original = f.cache.api;
  f.cache.api = async (route, options) => route.startsWith('actions/runs/10/artifacts?') ?
    {artifacts: [f.artifact]} : original(route, options);
  const expected = {...f.inputs}; delete expected.packages;
  const options = {runId: '10', temporary: f.root};
  assert.equal((await restoreEarly(f.cache, expected, f.builds, options)).hit, true);
  for (const field of ['phpCommit', 'extensionsCommit', 'coreCommit', 'platform']) {
    assert.equal((await restoreEarly(f.cache, {...expected, [field]: 'changed'}, f.builds, options)).hit, false);
  }
  assert.equal((await restoreEarly(f.cache, expected, f.builds, {...options, reuse: false})).hit, false);
});

test('archive fingerprints ignore php-darwin revisions but cover software and platform inputs', () => {
  const inputs = { php: '8.6', arch: 'arm64', build: 'debug', ts: 'zts', revision: 'a',
    phpCommit: 'b', extensionsCommit: 'c', platform: { compiler: 'clang-1' }, packages: [{ payload: 'a' }] };
  for (const key of Object.keys(inputs).filter(key => key !== 'revision')) assert.notEqual(checkpointKey(inputs), checkpointKey({ ...inputs, [key]: 'changed' }));
  assert.equal(checkpointKey(inputs), checkpointKey({...inputs, revision: 'different-code'}));
  assert.equal(checkpointKey({ a: 1, b: { c: 2, d: 3 } }), checkpointKey({ b: { d: 3, c: 2 }, a: 1 }));
});

test('installed keg bytes and links invalidate checkpoints, receipt and SBOM timestamps do not', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'keg-fingerprint-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.writeFileSync(path.join(root, 'library'), 'one');
  fs.writeFileSync(path.join(root, 'INSTALL_RECEIPT.json'), '{"time":1}');
  fs.writeFileSync(path.join(root, 'sbom.spdx.json'), '{"creationInfo":{"created":"2026-09-14T06:37:41Z"}}');
  fs.symlinkSync('library', path.join(root, 'link'));
  const baseline = kegDigest(root);
  fs.writeFileSync(path.join(root, 'INSTALL_RECEIPT.json'), '{"time":2}');
  fs.writeFileSync(path.join(root, 'sbom.spdx.json'), '{"creationInfo":{"created":"2026-09-14T07:08:37Z"}}');
  assert.equal(kegDigest(root), baseline);
  fs.writeFileSync(path.join(root, 'library'), 'two');
  assert.notEqual(kegDigest(root), baseline);
  fs.writeFileSync(path.join(root, 'library'), 'one');
  fs.unlinkSync(path.join(root, 'link'));
  fs.symlinkSync('other', path.join(root, 'link'));
  assert.notEqual(kegDigest(root), baseline);
});

test('a checkpoint from a previous run restores all verified variant files', async t => {
  const f = fixture(t);
  const destination = path.join(f.root, 'restored');
  const result = await restoreCheckpoint(f.cache, f.inputs, destination, { temporary: f.root });
  assert.equal(result.hit, true);
  assert.deepEqual(verifyCheckpoint(destination, f.inputs), f.item);
});

test('archive or metadata corruption is rejected before reuse', async t => {
  const f = fixture(t);
  fs.appendFileSync(path.join(f.builds, f.item.archive), 'corruption');
  assert.throws(() => verifyCheckpoint(f.builds, f.inputs), /mismatch/);
  fs.appendFileSync(path.join(f.staged, f.item.metadata), ' ');
  assert.throws(() => verifyCheckpoint(f.staged, f.inputs), /mismatch/);
  f.artifact.digest = 'sha256:' + '0'.repeat(64);
  const result = await restoreCheckpoint(f.cache, f.inputs, path.join(f.root, 'restore'), { temporary: f.root });
  assert.equal(result.hit, false);
  assert.match(f.warnings[0], /digest mismatch/);
});

test('changed inputs, expired artifacts, and explicit rebuilds cannot hit a checkpoint', async t => {
  const f = fixture(t);
  for (const inputs of [{ ...f.inputs, phpCommit: 'd'.repeat(40) }, f.inputs]) {
    if (inputs === f.inputs) f.artifact.expired = true;
    assert.equal((await restoreCheckpoint(f.cache, inputs, path.join(f.root, 'miss'), { temporary: f.root })).hit, false);
  }
  f.warnings.length = 0;
  f.cache.api = async () => { throw new Error('must not perform a lookup'); };
  assert.equal((await restoreCheckpoint(f.cache, f.inputs, f.builds, { reuse: false })).hit, false);
  assert.deepEqual(f.warnings, []);
});

test('checkpoint cleanup waits for upload and preserves other variants and architectures', async t => {
  const f = fixture(t);
  const artifacts = [
    { id: 1, name: f.item.prefix + 'old' },
    { id: 2, name: identity({ ...f.inputs, ts: 'nts' }).name },
    { id: 3, name: identity({ ...f.inputs, arch: 'x86_64' }).name },
  ];
  const deleted = [];
  const cache = { api: async (endpoint, options = {}) => {
    if (options.method === 'DELETE') deleted.push(endpoint);
    else {
      assert.equal(endpoint, 'actions/runs/10/artifacts?per_page=100&page=1');
      return { artifacts };
    }
  } };
  await assert.rejects(pruneCheckpoints(cache, f.item, '10'), /not uploaded/);
  assert.deepEqual(deleted, []);
  artifacts.push({ id: 4, name: f.item.name });
  await pruneCheckpoints(cache, f.item, '10');
  assert.deepEqual(deleted, ['actions/artifacts/1']);
});

test('legacy checkpoint bytes survive a php-darwin revision change without repackaging', async t => {
  const f = fixture(t);
  const sorted = value => Array.isArray(value) ? value.map(sorted) : value && typeof value === 'object' ?
    Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])])) : value;
  const legacyKey = crypto.createHash('sha256').update(JSON.stringify(sorted(f.inputs))).digest('hex');
  const checkpoint = path.join(f.staged, f.item.checkpoint);
  const metadata = JSON.parse(fs.readFileSync(checkpoint));
  metadata.key = legacyKey;
  fs.writeFileSync(checkpoint, JSON.stringify(metadata));
  command('zip', ['-q', f.zip, ...f.item.files], {cwd: f.staged});
  const data = fs.readFileSync(f.zip);
  f.artifact.name = f.item.prefix + legacyKey;
  f.artifact.digest = 'sha256:' + crypto.createHash('sha256').update(data).digest('hex');
  f.cache.api = async (route, options) => route.startsWith('actions/artifacts?') ?
    {artifacts: [f.artifact]} : options.consume(new Response(data));
  const destination = path.join(f.root, 'legacy-restored');
  const result = await restoreCheckpoint(f.cache, {...f.inputs, revision: 'f'.repeat(40)}, destination, {temporary: f.root});
  assert.equal(result.hit, true);
  assert.equal(fs.readFileSync(path.join(destination, f.item.archive), 'utf8'), 'verified native archive fixture');
  assert.deepEqual(f.warnings, []);
});
