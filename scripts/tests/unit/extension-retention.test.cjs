const {test} = require('node:test');
const assert = require('node:assert/strict');
const {staleArchives, retention} = require('../../release/extension-retention.cjs');
const {key, origins} = require('../../installer/install-extensions.cjs');
const {retryPolicy} = require('../../release/extension-transfers.cjs');

function entry(hash, version = '8.5', arch = 'arm64') {
  const value = {schema: 1, name: 'imagick', php_version: version, architecture: arch,
    build: 'release', thread_safety: 'nts', sha256: hash.repeat(64), inputs_sha256: 'a'.repeat(64),
    bytes: 1, php_api: '20250925', minimum_macos: 14};
  value.file = `${key(value)}-${value.sha256}.tar.zst`; return value;
}
const manifest = (...assets) => ({schema: 1, assets});

function inventoryFixture({missingOrigin} = {}) {
  const old = entry('a'), next = entry('b'), orphan = entry('c');
  const name = 'extensions-8.5-manifest.json', writes = [];
  const assets = [{name, id: 1}, ...[old, next, orphan].map((item, index) => ({name: item.file, id: index + 2}))];
  return {old, next, orphan, name, writes, run: async (program, args) => {
    if (args.includes('DELETE') || args.includes('delete-object')) { writes.push([program, ...args]); return ''; }
    if (program === 'gh') return JSON.stringify(args.includes('--paginate') ?
      [assets.filter(asset => missingOrigin !== origins[0] || asset.name !== name)] : {id: 10});
    return JSON.stringify({Contents: assets.filter(asset => missingOrigin !== origins[1] || asset.name !== name)
      .map(asset => ({Key: 'extensions/' + asset.name}))});
  }};
}

test('an inventoried manifest must be read on both origins before any archives are retired', async () => {
  for (const failedOrigin of origins) for (const recover of [true, false]) {
    const f = inventoryFixture(), waits = [];
    let failedReads = 0;
    const cleanup = retention({env: {}, endpoint: 'https://example.invalid', run: f.run,
      retry: retryPolicy({wait: async ms => waits.push(ms)}), fetcher: async url => {
        if (url.startsWith(failedOrigin) && (++failedReads < 3 || !recover)) return new Response('', {status: 404});
        return Response.json(manifest(url.startsWith(origins[0]) ? f.old : f.next));
      }});
    if (recover) {
      await cleanup.prune();
      assert.deepEqual(f.writes.map(args => args[0]), ['aws', 'gh']);
      assert.ok(f.writes[0].includes('extensions/' + f.orphan.file));
      assert.equal(f.writes[1].at(-1), 'repos/shivammathur/php-darwin/releases/assets/4');
    } else {
      await assert.rejects(cleanup.prune(), /HTTP 404/);
      assert.deepEqual(f.writes, []);
    }
    assert.equal(failedReads, 3);
    assert.deepEqual(waits, [1000, 2000]);
  }
});

test('a manifest absent from an origin inventory may return 404 without blocking cleanup', async () => {
  for (const missingOrigin of origins) {
    const f = inventoryFixture({missingOrigin}), waits = [];
    let missingReads = 0;
    const cleanup = retention({env: {}, endpoint: 'https://example.invalid', run: f.run,
      retry: retryPolicy({wait: async ms => waits.push(ms)}), fetcher: async url => {
        if (url.startsWith(missingOrigin)) { missingReads++; return new Response('', {status: 404}); }
        return Response.json(manifest(f.old, f.next));
      }});
    await cleanup.prune();
    assert.equal(missingReads, 1);
    assert.deepEqual(waits, []);
    assert.equal(cleanup.report.github_deleted, 1);
    assert.ok(f.writes[0].includes('extensions/' + f.orphan.file));
  }
});

test('invalid manifest bodies retry and never permit cleanup from the other origin alone', async () => {
  for (const body of [null, {}, {schema: 1, assets: [entry('a', '8.4')]}]) {
    const f = inventoryFixture();
    let reads = 0;
    const cleanup = retention({env: {}, endpoint: 'https://example.invalid', run: f.run,
      retry: retryPolicy({wait: async () => {}}), fetcher: async url => {
        if (url.startsWith(origins[0])) return Response.json(manifest(f.old));
        reads++;
        return Response.json(body);
      }});
    await assert.rejects(cleanup.prune(), /Invalid retention manifest|version mismatch/);
    assert.equal(reads, 3);
    assert.deepEqual(f.writes, []);
  }
});

test('R2 inventory retries malformed JSON three times without deleting from an incomplete listing', async () => {
  for (const recover of [true, false]) {
    let reads = 0;
    const waits = [], writes = [];
    const cleanup = retention({env: {}, endpoint: 'https://example.invalid',
      retry: retryPolicy({wait: async ms => waits.push(ms)}),
      run: async (program, args) => {
        if (args.includes('DELETE') || args.includes('delete-object')) writes.push(args);
        if (program === 'gh') return JSON.stringify(args.includes('--paginate') ? [[]] : {id: 1});
        reads++;
        return recover && reads === 3 ? '{"Contents":[]}' : '{"Contents":';
      },
    });
    if (recover) assert.deepEqual(await cleanup.prune(), []);
    else await assert.rejects(cleanup.prune(), SyntaxError);
    assert.equal(reads, 3);
    assert.deepEqual(waits, [1000, 2000]);
    assert.deepEqual(writes, []);
  }
});
test('retention protects both manifest commit points, other PHP versions, and incoming archives', () => {
  const old = entry('a'), next = entry('b'), other = entry('c', '8.4'), orphan = entry('d');
  const assets = [old, next, other, orphan].map(item => ({name: item.file}));
  const manifests = [{name: 'extensions-8.5-manifest.json', manifest: manifest(old)},
    {name: 'extensions-8.5-manifest.json', manifest: manifest(next)},
    {name: 'extensions-8.4-manifest.json', manifest: manifest(other)}];
  assert.deepEqual(staleArchives(assets, ['install-extensions.cjs', 'user-file'], manifests), [orphan.file]);
  assert.deepEqual(staleArchives(assets, [], manifests, [orphan.file]), []);
  manifests[0].manifest = manifest(next);
  assert.deepEqual(new Set(staleArchives(assets, [], manifests)), new Set([old.file, orphan.file]));
  manifests[0].manifest = manifest(other);
  assert.throws(() => staleArchives(assets, [], manifests), /version mismatch/);
});
test('retention deletes R2 first, leaves unrelated files, and tolerates interrupted publication', async () => {
  const old = entry('a'), next = entry('b'), calls = [];
  const assets = [{name: 'extensions-8.5-manifest.json', id: 1}, {name: old.file, id: 2}, {name: next.file, id: 3}];
  let committed = false;
  const run = async (program, args) => {
    calls.push([program, ...args]);
    if (args.includes('DELETE') || args.includes('delete-object')) return '';
    if (program === 'gh') return JSON.stringify(args.includes('--paginate') ? [assets] : {id: 10});
    return JSON.stringify({Contents: assets.map(item => ({Key: 'extensions/' + item.name}))});
  };
  const cleanup = retention({env: {}, endpoint: 'https://example.invalid', run,
    fetcher: async url => Response.json(manifest(committed || url.includes('github.com') ? next : old))});
  await cleanup.prune();
  assert.equal(cleanup.report.github_deleted, 0);
  committed = true;
  await cleanup.prune();
  assert.equal(cleanup.report.github_deleted, 1);
  const deletions = calls.filter(args => args.includes('DELETE') || args.includes('delete-object'));
  assert.deepEqual(deletions.map(args => args[0]), ['aws', 'gh']);
  assert.ok(deletions[0].includes('extensions/' + old.file));
});
test('failed manifest reads never delete archives; capacity can still permit a safe upload', async () => {
  const old = entry('a'), calls = [];
  const cleanup = retention({env: {}, endpoint: 'https://example.invalid',
    run: async (program, args) => {
      calls.push(args);
      if (program === 'aws') return JSON.stringify({Contents: []});
      return JSON.stringify(args.includes('--paginate') ? [[{name: old.file}, {name: 'extensions-8.5-manifest.json'}]] : {id: 1});
    }, fetcher: async () => new Response('', {status: 403})});
  await cleanup.capacity([entry('b').file]);
  assert.equal(cleanup.report.warnings.length, 1);
  assert.ok(calls.every(args => !args.includes('DELETE') && !args.includes('delete-object')));
});
