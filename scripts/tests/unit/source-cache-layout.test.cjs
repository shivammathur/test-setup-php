const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { releaseForFormula, productionRelease } = require('../../cache/source-cache-layout.cjs');
const { releaseAsset } = require('../../cache/source-bottle-releases.cjs');
const { keyFor } = require('../../cache/source-bottle-cache.cjs');
const { placement, copy, removeCopies, noActiveClaims, workers, migrate, migrationTransport } = require('../../cache/organize-source-cache.cjs');
const mirror = require('../../cache/source-bottle-mirror.cjs');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

test('named releases group PHP and extensions while retaining versioned core dependencies', () => {
  for (const formula of ['php', 'php@8.3', 'php-debug', 'php-debug-zts', 'shivammathur/php-zts/php@5.6-zts']) {
    assert.equal(releaseForFormula(formula), 'cache-php');
  }
  for (const name of ['imagick', 'mongodb', 'memcached', 'igbinary', 'msgpack', 'pcov', 'xdebug']) {
    for (const php of ['5.6', '7.4', '8.7']) assert.equal(releaseForFormula(`shivammathur/extensions/${name}@${php}`), `cache-${name}`);
    assert.equal(productionRelease(`cache-${name}`), true);
  }
  for (const formula of ['imagemagick', 'openssl@3', 'bison@2.7', 'libxml2', 'xz']) {
    assert.equal(releaseForFormula(formula), 'cache');
  }
  for (const tag of ['cache-locks', 'cache-source-a7', 'php-8.5', 'cache-../php']) assert.equal(productionRelease(tag), false);
});

function bundle(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'source-cache-organization-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const inputs = { formula: 'shivammathur/extensions/imagick@5.6', version: '3.8.1',
    environment: { arch: 'arm64', macos: '14', prefix: '/opt/homebrew' }, context: { build: 'debug', ts: 'zts' } };
  const key = keyFor(inputs), file = 'imagick@5.6--3.8.1.arm64_sonoma.bottle.tar.gz';
  const bytes = Buffer.from('fixture compiled bottle');
  fs.writeFileSync(path.join(root, file), bytes);
  fs.writeFileSync(path.join(root, 'metadata.json'), JSON.stringify({ schema: 1, key, file, sha256: sha(bytes), inputs }));
  const archive = path.join(root, 'bundle.tar');
  assert.equal(spawnSync('tar', ['-cf', archive, '-C', root, 'metadata.json', file]).status, 0);
  const data = fs.readFileSync(archive);
  const asset = { ...releaseAsset({ key, inputs }), id: 1, state: 'uploaded', digest: `sha256:${sha(data)}`, size: data.length };
  return { data, asset, entry: placement(asset, 'cache') };
}

test('migration copies exact bytes, falls back from a corrupt mirror and resumes verified uploads', async t => {
  const f = bundle(t), destination = new Map(); let uploaded, downloads = 0, uploads = 0;
  const cache = { repository: 'shivammathur/php-darwin', token: 'fixture', warn() {},
    async api(endpoint, options) {
      if (endpoint === 'releases/assets/1') { downloads++; return options.consume(new Response(f.data)); }
      assert.equal(endpoint, 'releases/assets/2'); return uploaded;
    }, async transfer(url, options, consume) {
      uploads++;
      const chunks = [];
      for await (const chunk of options().body) chunks.push(chunk);
      const bytes = Buffer.concat(chunks); assert.deepEqual(bytes, f.data);
      uploaded = { ...f.asset, id: 2 };
      return consume(Response.json(uploaded, { status: 201 }));
    } };
  const transport = { mirrorDownload: async (url, file) => { fs.writeFileSync(file, 'corrupt'); return 200; } };
  assert.equal((await copy(cache, f.entry, { id: 9 }, destination, transport)).result, 'copied');
  assert.equal((await copy(cache, f.entry, { id: 9 }, destination, transport)).result, 'existing');
  assert.equal(downloads, 1); assert.equal(uploads, 1);
  const record = mirror.record(uploaded, cache.repository, 'cache-imagick');
  assert.equal(mirror.key(record), mirror.key(mirror.record(f.asset)));
  assert.equal(mirror.record(uploaded, cache.repository, 'cache-mongodb'), undefined);
  destination.set(f.asset.name, { ...uploaded, digest: `sha256:${'a'.repeat(64)}` });
  await assert.rejects(copy(cache, f.entry, { id: 9 }, destination, transport), /Destination differs/);
  assert.equal(uploads, 1);
});

test('cleanup verifies every destination before deleting originals and rejects changed sources', async t => {
  const f = bundle(t); let saved = { ...f.asset, id: 2 }, source = f.asset; const deleted = [];
  const cache = { async release() { return { id: 9 }; }, async assets() { return [saved]; },
    async api(endpoint, options) {
      if (options?.method === 'DELETE') { deleted.push(endpoint); return; }
      return source;
    } };
  saved = { ...saved, digest: `sha256:${'0'.repeat(64)}` };
  await assert.rejects(removeCopies(cache, [f.entry]), /Destination verification failed/);
  assert.equal(deleted.length, 0);
  saved = { ...f.asset, id: 2 }; source = { ...f.asset, size: 7 };
  await assert.rejects(removeCopies(cache, [f.entry]), /Original asset changed/);
  assert.equal(deleted.length, 0);
  source = f.asset; await removeCopies(cache, [f.entry]);
  assert.deepEqual(deleted, ['releases/assets/1']);
});

test('migration stops for live or unidentifiable claims and lets completed owners retire', async () => {
  let status = 'in_progress';
  const claim = { id: 1, name: 'claim', label: JSON.stringify({ job: 2, run: 3 }) };
  const cache = { async release() { return null; }, async api() { return { run_id: 3, status }; } };
  await assert.rejects(noActiveClaims(cache, [claim]), /still active/);
  status = 'completed'; await noActiveClaims(cache, [claim]);
  await assert.rejects(noActiveClaims(cache, [{ ...claim, label: '{}' }]), /still active or unknown/);
});

test('deleted workflow owners retire only after both API checks and the expiry bound', async () => {
  const claim = { id: 1, name: 'claim', label: JSON.stringify({ job: 2, run: 3 }), created_at: '2000-01-01T00:00:00Z' };
  const calls = []; let run = { status: 'in_progress' };
  const cache = { async release() { return null; }, async api(endpoint) {
    calls.push(endpoint); return endpoint.startsWith('actions/jobs/') ? null : run;
  } };
  await assert.rejects(noActiveClaims(cache, [claim]), /still active/);
  run = null; await noActiveClaims(cache, [claim]);
  assert.deepEqual(calls.slice(-2), ['actions/jobs/2', 'actions/runs/3']);
  await assert.rejects(noActiveClaims(cache, [{ ...claim, created_at: new Date().toISOString() }]), /still active/);
});

test('failed migration workers finish in-flight copies without launching the rest', async () => {
  const started = [], finished = [];
  await assert.rejects(workers([1, 2, 3, 4], async value => {
    started.push(value);
    if (value === 1) throw new Error('copy failed');
    await new Promise(resolve => setImmediate(resolve)); finished.push(value);
  }, 2), /copy failed/);
  assert.deepEqual(started, [1, 2]); assert.deepEqual(finished, [2]);
});

test('bulk migration paces writes across both transports while reads remain independent', async () => {
  let clock = 1000; const writes = [];
  const transport = async (_url, options) => {
    if (options.method === 'DELETE') writes.push(clock);
    return new Response(null, { status: 204 });
  };
  const limited = migrationTransport({ request: transport, fallback: transport, now: () => clock,
    wait: async ms => { clock += ms; } });
  await limited.request('fixture', { method: 'GET' });
  assert.equal(clock, 1000);
  await Promise.all([limited.request('fixture', { method: 'DELETE' }),
    limited.fallbackRequest('fixture', { method: 'DELETE' }), limited.request('fixture', { method: 'DELETE' })]);
  assert.deepEqual(writes, [1000, 2000, 3000]);
});

test('quota exhaustion keeps migration requests stopped during bounded recovery', async () => {
  const { ReleaseCache } = require('../../cache/source-bottle-releases.cjs');
  let calls = 0;
  const transport = async () => {
    calls++;
    return Response.json({ message: 'API rate limit exceeded' }, { status: 403, headers: {
      'x-ratelimit-remaining': '0', 'x-ratelimit-limit': '1000', 'x-ratelimit-reset': '4000',
    } });
  };
  const limited = migrationTransport({ request: transport, fallback: transport, now: () => 1000,
    wait: async () => {} });
  const cache = new ReleaseCache({ repository: 'shivammathur/fixture', token: 'fixture', ...limited,
    wait: async () => {} });
  await assert.rejects(cache.api('releases'), /quota 0\/1000; resume after 1970-01-01T01:06:40.000Z.*API rate limit exceeded/);
  await assert.rejects(limited.fallbackRequest('fixture'), /Verified destination copies are retained/);
  assert.equal(calls, 1);
});

test('secondary quota responses retain the server wait and successful final reads remain consumable', async () => {
  const limited = migrationTransport({ now: () => 1000, request: async () => Response.json({ message: 'Secondary rate limit' }, {
    status: 429, headers: { 'retry-after': '120', 'x-ratelimit-remaining': '999' },
  }) });
  await assert.rejects(limited.request('fixture'), /resume after 1970-01-01T00:02:01.000Z.*Secondary rate limit/);
  let calls = 0;
  const exhausted = migrationTransport({ now: () => 1000, request: async () => {
    calls++; return Response.json({ ok: true }, { headers: { 'x-ratelimit-remaining': '0', 'x-ratelimit-reset': '4000' } });
  } });
  assert.deepEqual(await (await exhausted.request('fixture')).json(), { ok: true });
  await assert.rejects(exhausted.request('fixture'), /quota 0/);
  assert.equal(calls, 1);
});

test('migration frees the full legacy release before moving shared dependencies and removes only empty shard tags', async t => {
  const f = bundle(t), library = { ...f.asset, id: 2, name: f.asset.name.replace('imagick@5.6-', 'lz4-') };
  const releases = [{ id: 1, tag_name: 'cache', assets: [f.asset] },
    { id: 2, tag_name: 'cache-source-a7', assets: [library] }];
  const plan = { releases: [...releases], locks: [], entries: [f.entry, placement(library, 'cache-source-a7')] };
  const deletedTags = [];
  const cache = {
    async release(create, tag) {
      let release = releases.find(item => item.tag_name === tag);
      if (!release && create) { release = { id: 9, tag_name: tag, assets: [] }; releases.push(release); }
      return release;
    }, async assets(release) { return release.assets; },
    async api(endpoint, options) {
      if (endpoint === 'git/matching-refs/tags/cache-source-') return [{ ref: 'refs/tags/cache-source-a7' }, { ref: 'refs/tags/php-8.5' }];
      if (endpoint.startsWith('git/refs/tags/')) { deletedTags.push(endpoint); return; }
      if (endpoint === 'releases/2') {
        assert.equal(releases[1].assets.length, 0); releases.splice(1, 1); return;
      }
      const id = Number(endpoint.split('/').at(-1));
      const release = releases.find(r => r.assets.some(a => a.id === id));
      const asset = release?.assets.find(a => a.id === id);
      if (options?.method === 'DELETE') release.assets.splice(release.assets.indexOf(asset), 1);
      else return asset;
    },
  };
  const results = await migrate(cache, plan, { copyEntry: async (cache, entry, release, existing) => {
    if (entry.target === 'cache') assert.equal(release.assets.length, 0, 'legacy capacity must be freed first');
    const asset = { ...entry.asset, id: entry.asset.id + 10 };
    release.assets.push(asset); existing.set(asset.name, asset);
    return { result: 'copied' };
  } });
  assert.equal(results.length, 2);
  assert.deepEqual(deletedTags, ['git/refs/tags/cache-source-a7']);
  assert.deepEqual(releases.map(r => [r.tag_name, r.assets.length]), [['cache', 1], ['cache-imagick', 1]]);
});
