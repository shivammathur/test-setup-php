const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { ReleaseCache, family, releaseAsset, assetIdentity } = require('../../cache/source-bottle-releases.cjs');
const { keyFor, legacyKeyFor, readBottle } = require('../../cache/source-bottle-cache.cjs');
const { SourceBuildLock } = require('../../cache/source-build-lock.cjs');
const mirror = require('../../cache/source-bottle-mirror.cjs');
const digest = value => crypto.createHash('sha256').update(value).digest('hex');

function fixture(t, tag = 'cache', partition = false) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'release-bottle-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const state = { release: null, releases: [], assets: [], deleted: [], failDownload: false, uploadRace: false, next: 0, delays: [] };
  const request = async (url, options) => {
    const parsed = new URL(url);
    const endpoint = parsed.pathname.replace('/repos/shivammathur/php-darwin/', '');
    const json = (body, status = 200) => Response.json(body, { status });
    assert.ok(options.signal instanceof AbortSignal);
    const intercepted = await state.intercept?.(endpoint, options);
    if (intercepted) return intercepted;
    if (endpoint.startsWith('releases/tags/')) {
      const release = state.releases.find(item => item.tag_name === endpoint.slice('releases/tags/'.length));
      return json(release || null, release ? 200 : 404);
    }
    if (endpoint === 'releases' && options.method === 'POST') {
      const body = JSON.parse(options.body);
      assert.equal(body.make_latest, 'false');
      assert.equal(body.prerelease, tag.startsWith('source-bottles-test-'));
      if (state.releases.some(item => item.tag_name === body.tag_name)) return json({}, 422);
      state.release = { id: state.releases.length + 1, ...body };
      state.releases.push(state.release);
      return json(state.release, 201);
    }
    const releaseId = Number(endpoint.match(/^releases\/(\d+)\/assets$/)?.[1]);
    if (releaseId && options.method === 'POST') {
      const chunks = [];
      for await (const chunk of options.body) chunks.push(chunk);
      const data = Buffer.concat(chunks);
      const name = parsed.searchParams.get('name');
      const existing = state.assets.some(asset => asset.name === name && (asset.release_id || 1) === releaseId);
      if (!existing && state.assets.filter(asset => (asset.release_id || 1) === releaseId).length >= 1000) {
        return json({ errors: [{ resource: 'ReleaseAsset', field: 'file_count', code: 'custom',
          message: 'file_count limited to 1000 assets per release' }] }, 422);
      }
      if (!existing) state.assets.push({
        id: ++state.next, release_id: releaseId, name, label: parsed.searchParams.get('label'),
        state: 'uploaded', size: data.length, created_at: new Date().toISOString(),
        digest: `sha256:${digest(data)}`, data,
      });
      if (state.loseUploadReply) {
        state.loseUploadReply = false;
        throw new TypeError('fetch failed after upload');
      }
      return existing || state.uploadRace ? json({ errors: [{ resource: 'ReleaseAsset', field: 'name', code: 'already_exists' }] }, 422) : json({}, 201);
    }
    const offset = (Number(parsed.searchParams.get('page') || 1) - 1) * 100;
    if (releaseId) return json(state.assets.filter(asset => (asset.release_id || 1) === releaseId).slice(offset, offset + 100).map(({ data, ...asset }) =>
      state.omitDigest ? { ...asset, digest: undefined } : asset));
    const id = Number(endpoint.split('/').at(-1));
    const asset = state.assets.find(asset => asset.id === id);
    if (!asset) return json(null, 404);
    if (options.method === 'DELETE') {
      state.deleted.push(asset.name);
      state.assets = state.assets.filter(asset => asset.id !== id);
      return new Response(null, { status: 204 });
    }
    if (options.headers.Accept !== 'application/octet-stream') {
      const { data, ...metadata } = asset;
      return json(metadata);
    }
    if (state.failDownload) return new Response('unavailable', { status: 503 });
    return new Response(asset.data);
  };
  const cache = new ReleaseCache({ repository: 'shivammathur/php-darwin', token: 'fixture', tag, partition, request,
    wait: async delay => state.delays.push(delay), warn: () => {},
    versionsToPrune: versions => versions.filter(version => Number(version) < Math.max(...versions.map(Number))) });
  function bottle(version, overrides = {}) {
    const inputs = { formula: 'libxml2', version, environment: { arch: 'arm64', macos: '14', prefix: '/opt/homebrew' }, ...overrides };
    const key = keyFor(inputs);
    const directory = path.join(root, key);
    fs.mkdirSync(directory, { recursive: true });
    const file = `libxml2--${version}.arm64_sonoma.bottle.tar.gz`;
    const contents = `native compiled bottle ${version}`;
    fs.writeFileSync(path.join(directory, file), contents);
    fs.writeFileSync(path.join(directory, 'metadata.json'), JSON.stringify({
      schema: 1, key, file, sha256: digest(contents), inputs,
    }));
    return { directory, key, inputs, ...releaseAsset(JSON.parse(fs.readFileSync(path.join(directory, 'metadata.json')))) };
  }
  return { root, state, cache, bottle };
}

test('persistent release round-trip and pruning only older versions in the same package family', async t => {
  const f = fixture(t);
  const old = f.bottle('1');
  assert.equal(await f.cache.restoreCache([old.directory], old.key), undefined);
  await f.cache.saveCache([old.directory], old.key);
  const restored = path.join(f.root, 'restored');
  assert.equal(await f.cache.restoreCache([restored], old.key), old.key);
  assert.ok(readBottle(restored, old.key));
  const intel = f.bottle('1', { environment: { arch: 'x86_64', macos: '15', prefix: '/usr/local' } });
  await f.cache.saveCache([intel.directory], intel.key);
  const current = f.bottle('2');
  await f.cache.saveCache([current.directory], current.key);
  assert.deepEqual(f.state.deleted, [old.name]);
  assert.equal(await f.cache.restoreCache([restored], old.key), undefined);
  assert.ok(f.state.assets.some(asset => asset.name === intel.name));
  // An older job finishing later removes its own superseded version, never the newer one.
  await f.cache.saveCache([old.directory], old.key);
  assert.ok(f.state.assets.some(asset => asset.name === current.name));
  assert.ok(!f.state.assets.some(asset => asset.name === old.name));
});

test('preparing newer dependencies preserves the source bottle still approved for cache jobs', async t => {
  const f = fixture(t), old = f.bottle('1'), next = f.bottle('2');
  const file = path.join(f.root, 'dependencies.json');
  fs.writeFileSync(file, JSON.stringify({schema: 1, core_commit: 'a'.repeat(40), platforms: {
    arm64: {packages: {libxml2: {source: {key: old.key}}}},
  }}));
  f.cache.dependencyLockFile = file;
  await f.cache.saveCache([old.directory], old.key);
  await f.cache.saveCache([next.directory], next.key);
  assert.deepEqual(f.state.deleted, []);
  assert.equal(await f.cache.restoreCache([path.join(f.root, 'approved')], old.key), old.key);
});

test('uploads verify GitHub stored digests without downloading and restores prefer Cloudflare', async t => {
  const f = fixture(t);
  const bottle = f.bottle('1');
  f.cache.mirrorMissFile = path.join(f.root, 'misses.jsonl');
  f.cache.mirrorDownload = async () => assert.fail('matching upload digest needs no payload readback');
  f.state.failDownload = true;
  await f.cache.saveCache([bottle.directory], bottle.key);
  const asset = f.state.assets[0];
  const record = mirror.record(asset);
  assert.deepEqual(JSON.parse(fs.readFileSync(f.cache.mirrorMissFile)), record);
  fs.unlinkSync(f.cache.mirrorMissFile);
  f.cache.mirrorDownload = async (url, file) => {
    assert.equal(url, mirror.publicURL(record));
    fs.writeFileSync(file, asset.data);
    return 200;
  };
  f.state.intercept = (endpoint, options) => {
    assert.notEqual(options.headers.Accept, 'application/octet-stream', 'mirror hit downloaded GitHub payload');
  };
  const restored = path.join(f.root, 'mirror-restore');
  assert.equal(await f.cache.restoreCache([restored], bottle.key), bottle.key);
  assert.ok(readBottle(restored, bottle.key));
  assert.equal(fs.existsSync(f.cache.mirrorMissFile), false);
});

test('Cloudflare source bottle errors exhaust bounded retries before one GitHub fallback', async t => {
  for (const failure of ['missing', 'corrupt', 'unavailable']) {
    const f = fixture(t);
    const bottle = f.bottle('1');
    await f.cache.saveCache([bottle.directory], bottle.key);
    f.cache.mirrorMissFile = path.join(f.root, 'misses.jsonl');
    let attempts = 0, githubDownloads = 0;
    f.cache.mirrorDownload = async (url, file) => {
      attempts++;
      if (failure === 'unavailable') throw new Error('network unavailable');
      fs.writeFileSync(file, 'wrong bytes');
      return failure === 'missing' ? 404 : 200;
    };
    f.state.intercept = (endpoint, options) => {
      if (options.headers.Accept === 'application/octet-stream') githubDownloads++;
    };
    const restored = path.join(f.root, 'mirror-fallback');
    assert.equal(await f.cache.restoreCache([restored], bottle.key), bottle.key);
    assert.ok(readBottle(restored, bottle.key));
    assert.equal(attempts, failure === 'missing' ? 1 : 3);
    assert.equal(githubDownloads, 1);
    assert.deepEqual(JSON.parse(fs.readFileSync(f.cache.mirrorMissFile)), mirror.record(f.state.assets[0]));
  }
});

test('source mirror identities stay scoped to production and group one job per dependency', async t => {
  const f = fixture(t);
  const first = f.bottle('1');
  await f.cache.saveCache([first.directory], first.key);
  const asset = f.state.assets[0];
  const value = mirror.record(asset);
  assert.equal(mirror.record(asset, 'shivammathur/another-repo'), undefined);
  assert.equal(mirror.record(asset, 'shivammathur/php-darwin', 'source-bottles-test-1'), undefined);
  assert.equal(mirror.record({ ...asset, digest: null }), undefined);
  assert.equal(mirror.record({ ...asset, state: 'starter' }), undefined);
  for (const override of [{ name: '../outside.tar' }, { url: 'https://example.com/bottle' },
    { sha256: '../object' }, { formula: 'different' }, { version: 'other' },
    { source_key: `php-darwin-source-v1-${'b'.repeat(64)}` }]) {
    assert.throws(() => mirror.portable({ ...value, ...override }));
  }
  const changed = { ...value, sha256: 'a'.repeat(64) };
  const result = mirror.matrix([value, value, changed]);
  assert.equal(result.include.length, 1);
  assert.equal(result.include[0].bottles.length, 2);
  assert.deepEqual(mirror.matrix([value, changed], value.formula), result);
  assert.throws(() => mirror.matrix([value], 'missing'), /No cached source bottles/);
  assert.throws(() => mirror.matrix([value], '../invalid'), /Invalid source dependency/);
  assert.match(mirror.key(value), /^homebrew\/source-bottles\/sha256\/[a-f0-9]{64}\.tar$/);
});

test('source publication verifies Cloudflare bytes and uses the source prefix without GHCR authorization', async t => {
  const f = fixture(t);
  const bottle = f.bottle('1');
  await f.cache.saveCache([bottle.directory], bottle.key);
  const asset = f.state.assets[0];
  const value = mirror.record(asset);
  let uploaded = false, githubDownloads = 0, publicReads = 0;
  const options = {
    identity: mirror.portable, objectKey: mirror.key, contentType: 'application/x-tar', upstream: false,
    env: { CF_R2_AWS_S3_ENDPOINT: `https://${'a'.repeat(32)}.r2.cloudflarestorage.com`,
      CF_R2_AWS_ACCESS_KEY_ID: 'fixture', CF_R2_AWS_SECRET_ACCESS_KEY: 'fixture' },
    download: async (url, file, options) => {
      if (url === value.url) { assert.equal(options.upstream, false); githubDownloads++; }
      else {
        assert.ok(url.startsWith(mirror.publicURL(value)));
        publicReads++;
        if (!uploaded) return 404;
      }
      fs.writeFileSync(file, asset.data);
      return 200;
    },
    run: async (program, args) => {
      assert.equal(program, 'aws');
      assert.ok(args.includes(`s3://php-darwin/${mirror.key(value)}`));
      assert.equal(args[args.indexOf('--content-type') + 1], 'application/x-tar');
      assert.equal(uploaded, false);
      uploaded = true;
    },
  };
  const { publish } = require('../../cache/upstream-bottle-cache.cjs');
  assert.equal((await publish([value], options))[0].result, 'uploaded');
  assert.equal((await publish([value], options))[0].result, 'existing');
  assert.equal(githubDownloads, 1);
  assert.equal(publicReads, 3);
});

test('source build ownership permits one builder at a time and releases failed work', async t => {
  const f = fixture(t);
  const key = f.bottle('1').key;
  let active = 0;
  let maximum = 0;
  let releaseFirst;
  const firstCanFinish = new Promise(resolve => { releaseFirst = resolve; });
  f.state.intercept = endpoint => endpoint.startsWith('actions/jobs/') ?
    Response.json({ run_id: 10, status: 'in_progress' }) : undefined;
  f.cache.wait = async () => { releaseFirst(); await new Promise(resolve => setImmediate(resolve)); };
  const first = new SourceBuildLock(f.cache, { owner: { job: 1, run: 10, attempt: 1 } });
  const second = new SourceBuildLock(f.cache, { owner: { job: 2, run: 10, attempt: 1 } });
  await Promise.all([first.run(key, async () => {
    maximum = Math.max(maximum, ++active);
    await firstCanFinish;
    active--;
  }), second.run(key, async () => {
    maximum = Math.max(maximum, ++active);
    active--;
  })]);
  assert.equal(maximum, 1);
  assert.equal(f.state.assets.length, 0);
  await assert.rejects(first.run(key, async () => { throw new Error('compile failed'); }), /compile failed/);
  assert.equal(f.state.assets.length, 0);
});

test('a completed owner is recovered but an old active owner cannot be expired', async t => {
  const f = fixture(t);
  const key = f.bottle('1').key;
  let now = Date.now();
  let completed = false;
  f.state.intercept = endpoint => endpoint.startsWith('actions/jobs/') ?
    Response.json({ run_id: 10, status: completed ? 'completed' : 'in_progress' }) : undefined;
  const first = new SourceBuildLock(f.cache, { owner: { job: 1, run: 10, attempt: 1 } });
  const claim = await first.acquire(key);
  f.state.assets[0].created_at = '2000-01-01T00:00:00Z';
  f.cache.wait = async delay => { now += delay; };
  const second = new SourceBuildLock(f.cache, { owner: { job: 2, run: 11, attempt: 1 }, now: () => now, timeout: 20000 });
  await assert.rejects(second.acquire(key), /Timed out/);
  assert.ok(f.state.assets.some(asset => asset.id === claim.id));
  completed = true;
  await second.run(key, async () => {});
  assert.equal(f.state.assets.length, 0);
});

test('a lost ownership upload reply preserves the original claim', async t => {
  const f = fixture(t);
  const lock = new SourceBuildLock(f.cache, { owner: { job: 1, run: 10, attempt: 1 } });
  f.state.loseUploadReply = true;
  await lock.run(f.bottle('1').key, async () => assert.equal(f.state.assets.length, 1));
  assert.equal(f.state.assets.length, 0);
});

test('ownership polling recovers within three transport attempts without taking a live claim', async t => {
  const f = fixture(t), key = f.bottle('1').key;
  const first = new SourceBuildLock(f.cache, {owner: {job: 1, run: 10, attempt: 1}});
  const claim = await first.acquire(key);
  let now = Date.now(), checks = 0;
  f.cache.wait = async delay => {now += delay;};
  f.state.intercept = endpoint => {
    if (endpoint !== 'actions/jobs/1') return;
    assert.ok(f.state.assets.some(asset => asset.id === claim.id));
    checks++;
    if (checks <= 2) throw new DOMException('GitHub connection timed out', 'TimeoutError');
    if (checks === 3) return Response.json({run_id: 10, status: 'in_progress'});
    return Response.json({run_id: 10, status: 'completed'});
  };
  const second = new SourceBuildLock(f.cache, {owner: {job: 2, run: 11, attempt: 1}, now: () => now, timeout: 120000});
  let builds = 0;
  await second.run(key, async () => {
    builds++;
    assert.equal(checks, 4);
    assert.ok(!f.state.assets.some(asset => asset.id === claim.id));
  });
  assert.equal(builds, 1);
  assert.equal(f.state.assets.length, 0);
});

test('all exhausted owner-check errors remain bounded and preserve live claims', async t => {
  for (const status of [503, 403]) {
    const f = fixture(t), key = f.bottle('1').key;
    const first = new SourceBuildLock(f.cache, {owner: {job: 1, run: 10, attempt: 1}});
    const claim = await first.acquire(key);
    let now = Date.now(), checks = 0;
    const started = now;
    f.cache.wait = async delay => {now += delay;};
    f.state.intercept = endpoint => {
      if (endpoint === 'actions/jobs/1') {checks++; return new Response('unavailable', {status});}
    };
    const second = new SourceBuildLock(f.cache, {owner: {job: 2, run: 11, attempt: 1}, now: () => now, timeout: 20000});
    await assert.rejects(second.run(key, () => assert.fail('must not compile while ownership is unknown')),
      /503|403/);
    assert.ok(f.state.assets.some(asset => asset.id === claim.id));
    assert.equal(f.state.deleted.length, 0);
    assert.equal(checks, 3);
    assert.equal(now - started, 3000);
  }
});

test('transient upload 404s are retried before claiming ownership', async t => {
  const f = fixture(t);
  let uploads = 0;
  f.state.intercept = (endpoint, options) => {
    if (endpoint === 'releases/1/assets' && options.method === 'POST' && uploads++ === 0) {
      return new Response(null, { status: 404 });
    }
  };
  const lock = new SourceBuildLock(f.cache, { owner: { job: 1, run: 10, attempt: 1 } });
  await lock.run(f.bottle('1').key, async () => assert.equal(f.state.assets.length, 1));
  assert.equal(uploads, 2);
  assert.deepEqual(f.state.delays, [1000]);
  assert.equal(f.state.assets.length, 0);
});

test('a competing claim released before its lookup is retried safely', async t => {
  const f = fixture(t);
  let uploads = 0;
  f.state.intercept = (endpoint, options) => {
    if (endpoint === 'releases/1/assets' && options.method === 'POST' && uploads++ === 0) {
      return Response.json({ errors: [{ resource: 'ReleaseAsset', field: 'name', code: 'already_exists' }] }, { status: 422 });
    }
  };
  const lock = new SourceBuildLock(f.cache, { owner: { job: 1, run: 10, attempt: 1 } });
  await lock.run(f.bottle('1').key, async () => assert.equal(f.state.assets.length, 1));
  assert.equal(uploads, 2);
  assert.deepEqual(f.state.delays, [1000]);
});

test('conditional metadata reads revalidate changes and forget deleted state', async t => {
  const f = fixture(t);
  let request = 0;
  f.state.intercept = (endpoint, options) => {
    assert.equal(endpoint, 'actions/jobs/1');
    const etag = options.headers['If-None-Match'];
    switch (request++) {
      case 0:
        assert.equal(etag, undefined);
        return Response.json({ status: 'in_progress' }, { headers: { etag: 'one' } });
      case 1:
        assert.equal(etag, 'one');
        return new Response(null, { status: 304 });
      case 2:
        assert.equal(etag, 'one');
        return Response.json({ status: 'completed' }, { headers: { etag: 'two' } });
      case 3:
        assert.equal(etag, 'two');
        return new Response(null, { status: 404 });
      case 4:
        assert.equal(etag, undefined);
        return Response.json({ status: 'completed' });
      default: throw new Error('unexpected metadata request');
    }
  };
  assert.equal((await f.cache.api('actions/jobs/1')).status, 'in_progress');
  assert.equal((await f.cache.api('actions/jobs/1')).status, 'in_progress');
  assert.equal((await f.cache.api('actions/jobs/1')).status, 'completed');
  assert.equal(await f.cache.api('actions/jobs/1', { allow: [404] }), null);
  assert.equal((await f.cache.api('actions/jobs/1')).status, 'completed');
});

test('artifact ZIP requests use the Actions media type while streaming binary data', async t => {
  const f = fixture(t);
  f.state.intercept = (endpoint, options) => {
    assert.equal(options.headers.Accept, 'application/vnd.github+json');
    return new Response('zip bytes');
  };
  assert.equal(await f.cache.api('actions/artifacts/1/zip', { binary: true,
    accept: 'application/vnd.github+json', consume: response => response.text() }), 'zip bytes');
});

test('release requests retry failed responses and respect rate-limit backoff', async t => {
  const f = fixture(t);
  const responses = [new Response('temporarily unavailable', { status: 503 }),
    new Response('rate limited', { status: 429, headers: { 'retry-after': '7' } })];
  f.state.intercept = () => responses.shift();
  assert.equal(await f.cache.release(), null);
  assert.deepEqual(f.state.delays, [1000, 7000]);
});

test('release requests stop after three attempts including permission failures', async t => {
  const f = fixture(t);
  let attempts = 0;
  f.state.intercept = () => { attempts++; return new Response('unavailable', { status: 503 }); };
  await assert.rejects(f.cache.release(), /503/);
  assert.equal(attempts, 3);
  assert.deepEqual(f.state.delays, [1000, 2000]);
  f.state.delays = [];
  attempts = 0;
  f.state.intercept = () => { attempts++; return new Response('forbidden', { status: 403 }); };
  await assert.rejects(f.cache.release(), /403/);
  assert.equal(attempts, 3);
  assert.deepEqual(f.state.delays, [1000, 2000]);
});

test('a lost upload response recreates the stream and verifies the existing winner', async t => {
  const f = fixture(t);
  const current = f.bottle('2');
  f.state.loseUploadReply = true;
  await f.cache.saveCache([current.directory], current.key);
  assert.equal(f.state.assets.length, 1);
  assert.deepEqual(f.state.delays, [1000]);
  assert.equal(await f.cache.restoreCache([path.join(f.root, 'restored-upload')], current.key), current.key);
});

test('a stale empty upload is recovered without losing the previous verified version', async t => {
  const f = fixture(t);
  const old = f.bottle('1');
  await f.cache.saveCache([old.directory], old.key);
  const current = f.bottle('2');
  f.state.assets.push({ id: ++f.state.next, name: current.name, state: 'starter', size: 0,
    created_at: new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString(), data: Buffer.alloc(0) });
  assert.equal(await f.cache.restoreCache([path.join(f.root, 'incomplete')], current.key), undefined);
  await f.cache.saveCache([current.directory], current.key);
  assert.deepEqual(f.state.deleted, [current.name, old.name]);
  assert.equal(await f.cache.restoreCache([path.join(f.root, 'recovered')], current.key), current.key);
});

test('recent, nonempty, or undated incomplete uploads cannot be deleted', async t => {
  const f = fixture(t);
  await f.cache.release(true);
  const current = f.bottle('2');
  for (const attributes of [
    { size: 0, created_at: new Date().toISOString() },
    { size: 1, created_at: '2000-01-01T00:00:00Z' },
    { size: 0 },
  ]) {
    f.state.assets = [{ id: ++f.state.next, name: current.name, state: 'starter', ...attributes }];
    await f.cache.removeAbandonedUpload(f.state.release, current.name);
  }
  assert.deepEqual(f.state.deleted, []);
});

test('an upload that completes during stale-upload inspection is preserved', async t => {
  const f = fixture(t);
  const current = f.bottle('2');
  await f.cache.saveCache([current.directory], current.key);
  const saved = f.state.assets[0];
  f.state.intercept = (endpoint, options) => {
    if (endpoint === 'releases/1/assets' && options.method === 'GET') {
      return Response.json([{ ...saved, data: undefined, state: 'starter', size: 0,
        created_at: '2000-01-01T00:00:00Z' }]);
    }
  };
  await f.cache.removeAbandonedUpload(f.state.release, current.name);
  assert.deepEqual(f.state.deleted, []);
  assert.equal(f.state.assets[0].state, 'uploaded');
});

test('interrupted downloads restart the archive before checksum verification', async t => {
  const f = fixture(t);
  const current = f.bottle('2');
  await f.cache.saveCache([current.directory], current.key);
  let interrupted = false;
  f.state.intercept = endpoint => {
    if (endpoint.startsWith('releases/assets/') && !interrupted) {
      interrupted = true;
      return new Response(new ReadableStream({
        start(controller) { controller.enqueue(new Uint8Array([1, 2, 3])); },
        pull(controller) { controller.error(new TypeError('terminated')); },
      }));
    }
  };
  const restored = path.join(f.root, 'resumed-download');
  assert.equal(await f.cache.restoreCache([restored], current.key), current.key);
  assert.ok(readBottle(restored, current.key));
  assert.deepEqual(f.state.delays, [1000]);
});

test('temporary test releases remain prereleases', async t => {
  const f = fixture(t, 'source-bottles-test-123');
  const release = await f.cache.release(true);
  assert.equal(release.prerelease, true);
  assert.equal(release.make_latest, 'false');
});

test('failed remote verification preserves old versions', async t => {
  const f = fixture(t);
  const old = f.bottle('1');
  await f.cache.saveCache([old.directory], old.key);
  f.state.failDownload = true;
  f.state.omitDigest = true;
  const current = f.bottle('2');
  await assert.rejects(f.cache.saveCache([current.directory], current.key), /503/);
  assert.deepEqual(f.state.deleted, []);
});

test('concurrent upload winners are verified and reused without clobbering', async t => {
  const f = fixture(t);
  f.state.uploadRace = true;
  const current = f.bottle('2');
  await f.cache.saveCache([current.directory], current.key);
  await f.cache.saveCache([current.directory], current.key);
  assert.equal(f.state.assets.length, 1);
  assert.deepEqual(f.state.deleted, []);
});

test('a late older build does not prune against an unverified newer upload', async t => {
  const f = fixture(t);
  const old = f.bottle('1');
  await f.cache.saveCache([old.directory], old.key);
  f.state.failDownload = true;
  f.state.omitDigest = true;
  const current = f.bottle('2');
  await assert.rejects(f.cache.saveCache([current.directory], current.key), /503/);
  f.state.failDownload = false;
  f.state.omitDigest = false;
  f.state.assets.find(asset => asset.name === current.name).data = Buffer.from('corrupt');
  await assert.rejects(f.cache.saveCache([old.directory], old.key), /checksum/);
  assert.deepEqual(f.state.deleted, []);
});

test('corrupt release bytes are rejected before extracting a bottle', async t => {
  const f = fixture(t);
  const current = f.bottle('2');
  await f.cache.saveCache([current.directory], current.key);
  f.state.assets[0].data = Buffer.from('corrupt');
  const destination = path.join(f.root, 'corrupt');
  await assert.rejects(f.cache.restoreCache([destination], current.key), /checksum/);
  assert.ok(!fs.existsSync(destination));
});

test('cleanup keeps PHP extension ABI families separate', () => {
  const inputs = { formula: 'shivammathur/extensions/pcov@8.4', environment: { arch: 'arm64', macos: '14' },
    context: { build: 'release', ts: 'nts', php: { version: '8.4.1' } } };
  assert.notEqual(family(inputs), family({ ...inputs, context: { ...inputs.context, ts: 'zts' } }));
  assert.notEqual(family(inputs), family({ ...inputs, context: { ...inputs.context, build: 'debug' } }));
  assert.equal(family(inputs), family({ ...inputs, context: { ...inputs.context, php: { version: '8.4.2' } } }));
});

test('readable names preserve full cache identity independently of display labels', () => {
  const inputs = { formula: 'shivammathur/extensions/xdebug@8.4', version: '3.5.3_1',
    environment: { arch: 'arm64', macos: '14', prefix: '/opt/homebrew' },
    context: { build: 'debug', ts: 'zts' } };
  const key = keyFor(inputs);
  const asset = releaseAsset({ inputs, key });
  assert.equal(asset.label, `xdebug@8.4-3.5.3_1.macos-14.arm64.debug-zts.${key.slice(-64, -52)}.tar`);
  assert.ok(asset.name.startsWith('xdebug@8.4-3.5.3_1.macos-14.arm64.debug-zts.'));
  assert.deepEqual(assetIdentity({ ...asset, label: 'Edited in GitHub' }),
    { version: inputs.version, group: family(inputs), key });
  assert.equal(assetIdentity({ name: asset.label }), undefined);
});

test('single-hyphen filenames preserve hyphenated package names and versions', () => {
  for (const version of ['2026-09-14', '1.2.3-rc-2', '3.5.3_1']) {
    const inputs = { formula: 'vendor/tap/lib-2-tools', version,
      environment: { arch: 'arm64', macos: '14', prefix: '/opt/homebrew' } };
    const key = keyFor(inputs);
    const asset = releaseAsset({ inputs, key });
    assert.ok(asset.label.startsWith(`lib-2-tools-${version}.macos-14.arm64.`));
    assert.deepEqual(assetIdentity(asset), { version, group: family(inputs), key });
  }
});

test('double-hyphen assets restore and are pruned after a single-hyphen replacement', async t => {
  const f = fixture(t);
  const old = f.bottle('1');
  await f.cache.saveCache([old.directory], old.key);
  const legacy = f.state.assets[0];
  const { group } = assetIdentity(legacy);
  legacy.name = `libxml2--1.macos-14.arm64.source-v1-${group}.${old.key.slice(-64)}.tar`;
  legacy.label = `libxml2--1.macos-14.arm64.${old.key.slice(-64, -52)}.tar`;
  assert.equal(await f.cache.restoreCache([path.join(f.root, 'double-hyphen')], old.key), old.key);
  const current = f.bottle('2');
  await f.cache.saveCache([current.directory], current.key);
  assert.deepEqual(f.state.deleted, [legacy.name]);
  assert.deepEqual(f.state.assets.map(asset => asset.name), [current.name]);
});

test('legacy assets restore and are pruned when a readable replacement is verified', async t => {
  const f = fixture(t);
  const old = f.bottle('1');
  await f.cache.saveCache([old.directory], old.key);
  const legacy = f.state.assets[0];
  const identity = assetIdentity(legacy);
  legacy.name = `${old.key}.tar`;
  legacy.label = `source-v1:${identity.group}:1`;
  assert.equal(await f.cache.restoreCache([path.join(f.root, 'legacy')], old.key), old.key);
  const current = f.bottle('2');
  await f.cache.saveCache([current.directory], current.key);
  assert.deepEqual(f.state.deleted, [legacy.name]);
  assert.deepEqual(f.state.assets.map(asset => asset.name), [current.name]);
});

test('same-version recipe edits reuse one cache and ignore edited display labels', async t => {
  const f = fixture(t);
  const first = f.bottle('1', { recipe: 'first' });
  const second = f.bottle('1', { recipe: 'second' });
  await f.cache.saveCache([first.directory], first.key);
  f.state.assets[0].label = 'Custom display name';
  await f.cache.saveCache([second.directory], second.key);
  assert.equal(f.state.assets.length, 1);
  assert.deepEqual(f.state.deleted, []);
  assert.equal(await f.cache.restoreCache([path.join(f.root, 'first')], first.key), first.key);
  assert.equal(await f.cache.restoreCache([path.join(f.root, 'second')], second.key), second.key);
  const next = f.bottle('2');
  await f.cache.saveCache([next.directory], next.key);
  assert.deepEqual(f.state.deleted, [first.name]);
});

test('a full legacy release remains reusable while new bottles and claims use separate releases', async t => {
  const f = fixture(t);
  const old = f.bottle('1', { formula: 'shivammathur/extensions/imagick@5.6' });
  await f.cache.saveCache([old.directory], old.key);
  const legacyAsset = f.state.assets[0];
  for (let i = 1; i < 1000; i++) f.state.assets.push({ id: ++f.state.next, release_id: 1, name: `preserved-${i}` });
  f.cache.partition = true;
  f.cache.mirrorMissFile = path.join(f.root, 'partition-misses.jsonl');
  const mirrorReads = [];
  f.cache.mirrorDownload = async (url, file) => {
    mirrorReads.push(url);
    const asset = f.state.assets.find(item => item.digest && url.endsWith(`${item.digest.slice(7)}.tar`));
    assert.ok(asset);
    fs.writeFileSync(file, asset.data);
    return 200;
  };
  const restored = path.join(f.root, 'partition-restored');
  assert.equal(await f.cache.restoreCache([restored], old.key, [], old.inputs), old.key);
  assert.equal(mirrorReads[0], mirror.publicURL(mirror.record(legacyAsset)));
  const current = f.bottle('2', { formula: 'shivammathur/extensions/imagick@5.6' });
  await f.cache.saveCache([current.directory], current.key);
  const shard = f.state.releases.find(item => item.tag_name === f.cache.bottleTag(current.inputs));
  assert.equal(shard.tag_name, 'cache-imagick');
  const saved = f.state.assets.find(item => item.name === current.name);
  assert.equal(saved.release_id, shard.id);
  const queued = JSON.parse(fs.readFileSync(f.cache.mirrorMissFile));
  assert.deepEqual(queued, mirror.record(saved, 'shivammathur/php-darwin', shard.tag_name));
  assert.ok(queued.url.includes(`/download/${shard.tag_name}/`));
  assert.equal(await f.cache.restoreCache([restored], current.key, [], current.inputs), current.key);
  assert.ok(readBottle(restored, current.key));
  const older = f.bottle('0', { formula: 'shivammathur/extensions/imagick@5.6' });
  await f.cache.saveCache([older.directory], older.key);
  assert.ok(f.state.deleted.includes(older.name));
  assert.ok(f.state.assets.includes(legacyAsset), 'legacy cached builds must remain intact');
  const lock = new SourceBuildLock(f.cache, { owner: { job: 1, run: 10, attempt: 1 } });
  await lock.run(current.key, async () => {
    const claim = f.state.assets.find(item => item.name.startsWith('source-build-lock-'));
    assert.equal(f.state.releases.find(item => item.id === claim.release_id).tag_name, 'cache-locks');
  });
  assert.equal(f.state.assets.filter(item => item.release_id === 1).length, 1000);
  assert.equal(f.state.assets.some(item => item.name.startsWith('source-build-lock-')), false);
  assert.deepEqual(f.state.delays, []);
  await assert.rejects(f.cache.restoreCache([restored], current.key, [], old.inputs), /matching build inputs/);
});

test('release capacity and unknown 422 failures exhaust bounded retries without starting a compile', async t => {
  for (const body of [{ errors: [{ resource: 'ReleaseAsset', field: 'file_count', code: 'custom',
    message: 'file_count limited to 1000 assets per release' }] }, { message: 'Validation failed' }]) {
    const f = fixture(t);
    let requests = 0;
    f.state.intercept = (endpoint, options) => {
      if (endpoint === 'releases/1/assets' && options.method === 'POST') {
        requests++;
        return Response.json(body, { status: 422 });
      }
    };
    const bottle = f.bottle('1');
    const lock = new SourceBuildLock(f.cache, { owner: { job: 1, run: 10, attempt: 1 } });
    await assert.rejects(lock.run(bottle.key, () => assert.fail('must not compile without ownership')), /Source build claim: HTTP 422/);
    await assert.rejects(f.cache.saveCache([bottle.directory], bottle.key), /Source bottle upload: HTTP 422/);
    assert.equal(requests, 6);
    assert.deepEqual(f.state.delays, [1000, 2000, 1000, 2000]);
  }
});

test('mirror records accept only production source shards and preserve digest-based Cloudflare addresses', async t => {
  const f = fixture(t);
  const bottle = f.bottle('1');
  await f.cache.saveCache([bottle.directory], bottle.key);
  const asset = f.state.assets[0];
  const legacy = mirror.record(asset);
  const sharded = mirror.record(asset, 'shivammathur/php-darwin', 'cache-source-a7');
  assert.equal(mirror.key(sharded), mirror.key(legacy));
  assert.equal(mirror.portable(sharded).url, sharded.url);
  for (const tag of ['cache-locks', 'cache-source-xyz', 'cache-source-A7', 'cache-source-a7/../other']) {
    assert.equal(mirror.record(asset, 'shivammathur/php-darwin', tag), undefined);
    assert.throws(() => mirror.portable({ ...legacy, url: legacy.url.replace('/cache/', `/${tag}/`) }));
  }
});


test('legacy PHP and dependency keys restore across code edits without replacing release bytes', async t => {
  for (const formula of ['gcc', 'shivammathur/php/php@8.5', 'shivammathur/extensions/imagick@8.5']) {
    const f = fixture(t, 'cache', true);
    const old = f.bottle('1', {formula, recipe: 'old',
      context: formula.includes('extensions') ? {build: 'debug', ts: 'zts', abstract: 'old', php: {version: '8.5.0', api: {PHP_API_VERSION: '123'}}} : undefined});
    const file = path.join(old.directory, 'metadata.json');
    const metadata = JSON.parse(fs.readFileSync(file));
    metadata.key = legacyKeyFor(metadata.inputs);
    fs.writeFileSync(file, JSON.stringify(metadata));
    await f.cache.saveCache([old.directory], metadata.key);
    const original = Buffer.from(f.state.assets[0].data);
    const updated = {...old.inputs, recipe: 'patched', environment: {...old.inputs.environment, compiler: 'new clang'}};
    if (updated.context) updated.context = {...updated.context, abstract: 'patched'};
    const key = keyFor(updated), destination = path.join(f.root, 'restored');
    assert.equal(await f.cache.restoreCache([destination], key, [], updated), key);
    assert.ok(readBottle(destination, key));
    assert.deepEqual(f.state.assets[0].data, original);
    assert.deepEqual(f.state.deleted, []);
    const incompatible = {...updated, dependencies: [{name: 'libxml2', version: '2'}]};
    assert.equal(await f.cache.restoreCache([path.join(f.root, 'incompatible')], keyFor(incompatible), [], incompatible), undefined);
    f.state.assets[0].data[0] ^= 1;
    assert.equal(await f.cache.restoreCache([path.join(f.root, 'corrupt')], key, [], updated), undefined);
  }
});
