const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { prefetch, matrix, publish, publicURL, key, validate, exec } = require('../../cache/upstream-bottle-cache.cjs');
const { retryPolicy, command } = require('../../release/extension-transfers.cjs');
const bytes = Buffer.from('a verified bottle archive');
const digest = crypto.createHash('sha256').update(bytes).digest('hex');
function record(overrides = {}) {
  return { formula: 'gcc', version: '16.2.0', tag: 'sequoia', sha256: digest,
    url: `https://ghcr.io/v2/homebrew/core/gcc/blobs/sha256:${digest}`, ...overrides };
}
function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'bottle-cache-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return { record: record({ cached_download: path.join(directory, 'downloads', 'gcc.tar.gz') }),
    retry: retryPolicy({ wait: async () => {} }), directory, missFile: path.join(directory, 'misses.jsonl'), log: () => {}, warn: () => {} };
}
test('tools entry point loads the resolver without partially initialized cache exports', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.directory, 'brew'), '#!/bin/sh\nprintf "[]\\n"\n', { mode: 0o755 });
  const result = spawnSync(process.execPath, [path.join(__dirname, '../../cache/upstream-bottle-cache.cjs'), 'tools'], {
    env: { ...process.env, PATH: `${f.directory}${path.delimiter}${process.env.PATH}` }, encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
  assert.equal(result.stdout, '');
});
test('verified Cloudflare bytes populate the exact Homebrew path without upstream transfer', async t => {
  const f = fixture(t);
  await prefetch([f.record], { ...f, download: async (url, file) => {
    assert.equal(url, publicURL(f.record)); fs.writeFileSync(file, bytes); return 200;
  } });
  assert.deepEqual(fs.readFileSync(f.record.cached_download), bytes);
  assert.equal(fs.existsSync(f.missFile), false);
  assert.deepEqual(fs.readdirSync(path.dirname(f.record.cached_download)), ['gcc.tar.gz']);
});
test('404, outage, and corrupt bottles queue exact identities without installing partial data', async t => {
  for (const failure of ['miss', 'outage', 'corrupt']) {
    const f = fixture(t);
    await prefetch([f.record], { ...f, download: async (url, file) => {
      fs.writeFileSync(file, 'incomplete');
      if (failure === 'outage') throw new Error('network unavailable');
      return failure === 'miss' ? 404 : 200;
    } });
    assert.equal(fs.existsSync(f.record.cached_download), false);
    assert.deepEqual(fs.readdirSync(path.dirname(f.record.cached_download)), []);
    assert.equal(JSON.parse(fs.readFileSync(f.missFile)).sha256, digest);
    assert.equal(JSON.parse(fs.readFileSync(f.missFile)).cached_download, undefined);
  }
});
test('valid local downloads are preserved and an uncached revision is queued', async t => {
  const f = fixture(t);
  fs.mkdirSync(path.dirname(f.record.cached_download));
  fs.writeFileSync(f.record.cached_download, bytes);
  await prefetch([f.record], { ...f, download: async (url, file, options) => {
    assert.equal(options.head, true); assert.equal(file, os.devNull); return 404;
  } });
  assert.deepEqual(fs.readFileSync(f.record.cached_download), bytes);
  assert.equal(JSON.parse(fs.readFileSync(f.missFile)).sha256, digest);
});
test('one matrix job per dependency deduplicates variants but retains new digests and platforms', () => {
  const otherDigest = 'a'.repeat(64);
  const next = record({ sha256: otherDigest, tag: 'arm64_sonoma',
    url: `https://ghcr.io/v2/homebrew/core/gcc/blobs/sha256:${otherDigest}` });
  const result = matrix([record(), record(), next]);
  assert.equal(result.include.length, 1);
  assert.equal(result.include[0].bottles.length, 2);
  assert.notEqual(key(record()), key(next));
});
test('untrusted records cannot choose upload paths or authenticated network destinations', () => {
  for (const bad of [ { sha256: '../outside' }, { formula: '../gcc' }, { tag: '' },
    { url: 'https://example.com/bottle' }, { url: record().url + '?token=secret' },
    { url: record().url.replace('homebrew/core', 'untrusted/tap') },
    { url: record().url.replace(digest, 'b'.repeat(64)) } ]) {
    assert.throws(() => validate(record(bad)));
  }
});
const env = { CF_R2_AWS_S3_ENDPOINT: `https://${'a'.repeat(32)}.r2.cloudflarestorage.com`,
  CF_R2_AWS_ACCESS_KEY_ID: 'test-access', CF_R2_AWS_SECRET_ACCESS_KEY: 'test-secret' };
test('publish checks upstream and public download hashes and uses only the bottle prefix', async () => {
  let uploaded = false, reads = 0;
  const results = await publish([record()], { env, download: async (url, file, options) => {
    reads++;
    if (url.startsWith('https://ghcr.io/')) assert.equal(options.upstream, true);
    else if (!uploaded) return 404;
    fs.writeFileSync(file, bytes); return 200;
  }, run: async (program, args, options) => {
    assert.equal(program, 'aws');
    assert.ok(args.includes(`s3://php-darwin/${key(record())}`));
    assert.equal(options.env.AWS_MAX_ATTEMPTS, '1');
    assert.equal(options.env.AWS_ACCESS_KEY_ID, env.CF_R2_AWS_ACCESS_KEY_ID);
    uploaded = true;
  } });
  assert.equal(reads, 3); assert.equal(results[0].result, 'uploaded');
});
test('publication refuses corrupt upstream data and a corrupt public readback', async () => {
  for (const corruptUpstream of [true, false]) {
    let uploaded = false;
    await assert.rejects(publish([record()], { env, download: async (url, file) => {
      if (!url.startsWith('https://ghcr.io/') && !uploaded) return 404;
      fs.writeFileSync(file, (url.startsWith('https://ghcr.io/') && !corruptUpstream) ? bytes : 'corrupt');
      return 200;
    }, run: async () => { assert.equal(corruptUpstream, false); uploaded = true; } }),
    corruptUpstream ? /Invalid upstream/ : /verification failed/);
  }
});
test('existing verified objects require no upstream request or upload', async () => {
  const result = await publish([record()], { env, download: async (url, file) => {
    assert.equal(url, publicURL(record())); fs.writeFileSync(file, bytes); return 200;
  }, run: async () => { assert.fail('unexpected upload'); } });
  assert.equal(result[0].result, 'existing');
});

test('source mirror publication retries all failed reads without uploads and bounds persistent failures', async () => {
  for (const mode of ['recover', 'timeout', 'forbidden']) {
    const waits = [];
    let reads = 0;
    const retry = retryPolicy({ attempts: 3, budget: 12, delay: 1000, wait: async pause => waits.push(pause) });
    const work = publish([record()], { env, retry, download: async (_url, file) => {
      reads++;
      if (mode === 'timeout') throw Object.assign(new Error('body timeout'), { transient: true });
      if (mode === 'forbidden') return 403;
      if (reads < 3) return reads === 1 ? 524 : 503;
      fs.writeFileSync(file, bytes); return 200;
    }, run: async () => assert.fail('read failures must not trigger uploads') });
    if (mode === 'recover') assert.equal((await work)[0].result, 'existing');
    else await assert.rejects(work, mode === 'timeout' ? /body timeout/ : /403/);
    assert.equal(reads, 3);
    assert.deepEqual(waits, [1000, 2000]);
  }
});

test('both curl process adapters retry any error within the same bound', async t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.directory, 'curl'), '#!/bin/sh\nprintf "000"\nexit "$1"\n', { mode: 0o755 });
  const options = { env: { ...process.env, PATH: `${f.directory}${path.delimiter}${process.env.PATH}` } };
  for (const run of [exec, command]) {
    for (const code of [16, 35, 58, 60, 77, 3, 23]) {
      await assert.rejects(run('curl', [String(code)], options), error => {
        assert.equal(Boolean(error.transient), true);
        assert.equal(error.output, '000');
        return true;
      });
    }
  }
  for (const mode of ['recover', 'persistent', 'certificate']) {
    let reads = 0;
    const waits = [];
    const retry = retryPolicy({ attempts: 3, budget: 12, delay: 1000, wait: async pause => waits.push(pause) });
    const work = publish([record()], { env, retry, download: async (_url, file) => {
      if (++reads < 3 || mode !== 'recover') await exec('curl', [mode === 'certificate' ? '60' : '35'], options);
      fs.writeFileSync(file, bytes);
      return 200;
    }, run: async () => assert.fail('TLS read recovery must not upload or rebuild a valid bottle') });
    if (mode === 'recover') assert.equal((await work)[0].result, 'existing');
    else await assert.rejects(work, /curl exited/);
    assert.equal(reads, 3);
    assert.deepEqual(waits, [1000, 2000]);
  }
});

test('upstream source downloads share the bounded retry policy before one verified upload', async () => {
  let uploaded = false, upstreamReads = 0, uploads = 0;
  const waits = [];
  const result = await publish([record()], { env,
    retry: retryPolicy({ attempts: 3, delay: 1000, wait: async pause => waits.push(pause) }),
    download: async (url, file) => {
      if (url.startsWith('https://ghcr.io/')) {
        if (++upstreamReads === 1) throw Object.assign(new Error('TLS reset'), { transient: true });
        if (upstreamReads === 2) return 503;
      } else if (!uploaded) return 404;
      fs.writeFileSync(file, bytes); return 200;
    }, run: async () => { uploaded = true; uploads++; },
  });
  assert.equal(result[0].result, 'uploaded');
  assert.equal(upstreamReads, 3);
  assert.equal(uploads, 1);
  assert.deepEqual(waits, [1000, 2000]);
});

test('public 404 after upload checks R2 directly and fails without another upload', async () => {
  const calls = [];
  await assert.rejects(publish([record()], { env, download: async (url, file) => {
    const upstream = url.startsWith('https://ghcr.io/');
    fs.writeFileSync(file, upstream ? bytes : 'not found');
    return upstream ? 200 : 404;
  }, run: async (program, args, options) => {
    assert.equal(program, 'aws');
    assert.equal(options.env.AWS_MAX_ATTEMPTS, '1');
    calls.push(args[2]);
    if (args[2] === 's3api') {
      assert.ok(args.includes('head-object'));
      assert.equal(args[args.indexOf('--key') + 1], key(record()));
      return JSON.stringify({ ContentLength: bytes.length, ETag: 'fixture' });
    }
  } }), /verification failed: gcc HTTP 404/);
  assert.deepEqual(calls, ['s3', 's3api']);
});

test('R2 object metadata retries malformed JSON without repeating a completed upload', async () => {
  for (const recover of [true, false]) {
    let reads = 0, uploads = 0;
    const work = publish([record()], {env, retry: retryPolicy({wait: async () => {}}),
      download: async (url, file) => {
        if (!url.startsWith('https://ghcr.io/')) return 404;
        fs.writeFileSync(file, bytes);
        return 200;
      },
      run: async (_program, args) => {
        if (args.includes('head-object')) {
          reads++;
          return recover && reads === 3 ? JSON.stringify({ContentLength: bytes.length, ETag: 'fixture'}) : '{';
        }
        uploads++;
      },
    });
    await assert.rejects(work, recover ? /verification failed: gcc HTTP 404/ : SyntaxError);
    assert.equal(reads, 3);
    assert.equal(uploads, 1);
  }
});

test('R2 upload retries permission failures but reuses a committed object after a lost reply', async () => {
  for (const mode of ['lost', 'permission', 'corrupt-readback']) {
    let uploaded = false, uploads = 0, readbacks = 0;
    const waits = [];
    const work = publish([record()], {env, retry: retryPolicy({wait: async ms => waits.push(ms)}),
      download: async (url, file) => {
        if (!url.startsWith('https://ghcr.io/') && !uploaded) return 404;
        const corrupt = uploaded && mode === 'corrupt-readback' && ++readbacks < 3;
        fs.writeFileSync(file, corrupt ? 'corrupt response' : bytes);
        return 200;
      }, run: async (_program, _args, options) => {
        uploads++;
        assert.equal(options.env.AWS_MAX_ATTEMPTS, '1');
        if (mode === 'permission') throw new Error('AccessDenied');
        uploaded = true;
        if (mode === 'lost') throw new Error('lost successful upload reply');
      }
    });
    if (mode === 'permission') { await assert.rejects(work, /AccessDenied/); assert.equal(uploads, 3); }
    else { assert.equal((await work)[0].result, 'uploaded'); assert.equal(uploads, 1); }
    assert.deepEqual(waits, mode === 'lost' ? [1000] : [1000, 2000]);
  }
});
