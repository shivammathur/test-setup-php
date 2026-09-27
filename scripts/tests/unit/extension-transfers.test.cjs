const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { command, retryPolicy, httpError, readDiagnostic, transfers, githubJSON } = require('../../release/extension-transfers.cjs');
const { digest } = require('../../installer/install-extensions.cjs');

function fixture(t, failure) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-transfers-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const file = path.join(directory, 'pack.tar.zst');
  fs.writeFileSync(file, 'verified archive');
  const github = new Map(), cloudflare = new Map(), cachedMissing = new Set(), calls = [], waits = [];
  const cacheMissing = ['cached-miss', 'cloudflare-response'].includes(failure);
  const run = async (program, args) => {
    calls.push({ program, args });
    if (program === 'gh' && args[0] === 'api') {
      return JSON.stringify(args.includes('--paginate') ? [[...github.values()]] : { id: 123 });
    }
    if (program === 'gh') {
      const body = fs.readFileSync(args[3]), name = path.basename(args[3]);
      github.set(name, { name, size: body.length, digest: `sha256:${digest(body)}` });
      if (failure === 'github-response') { failure = ''; throw httpError(503, 'Lost upload response'); }
    } else if (program === 'aws' && args.includes('put-object')) {
      if (failure === 'credentials') throw new Error('AccessDenied');
      const body = fs.readFileSync(args[args.indexOf('--body') + 1]);
      cloudflare.set(path.basename(args[args.indexOf('--key') + 1]), body);
      if (failure === 'cloudflare-response') { failure = ''; throw httpError(503, 'Lost upload response'); }
    } else if (program === 'aws') return JSON.stringify({ ContentLength: 16, ETag: 'test' });
    else if (program === 'curl') {
      const url = new URL(args.at(-1)), name = path.basename(url.pathname);
      if (failure === 'edge-503') { failure = ''; return '503'; }
      if (cacheMissing && !url.search && cachedMissing.has(name)) return '404';
      if (!cloudflare.has(name)) { cachedMissing.add(name); return '404'; }
      fs.writeFileSync(args[args.indexOf('--output') + 1], cloudflare.get(name));
      return '200';
    }
    return '';
  };
  const retry = retryPolicy({ wait: async ms => waits.push(ms) });
  const create = () => transfers({ directory, endpoint: 'https://test.invalid', env: { AWS_MAX_ATTEMPTS: '1' }, run, retry, cloudflareRetry: retry });
  return { file, calls, waits, github, cloudflare, create };
}
test('GitHub JSON reads retry truncated responses and stop after three malformed responses', async () => {
  for (const recover of [true, false]) {
    let calls = 0;
    const waits = [];
    const request = githubJSON('repos/example/project/actions/runs', {
      paginate: true,
      retry: retryPolicy({wait: async ms => waits.push(ms)}),
      run: async (program, args) => {
        assert.equal(program, 'gh');
        assert.deepEqual(args, ['api', '--paginate', '--slurp', 'repos/example/project/actions/runs']);
        calls++;
        return recover && calls === 3 ? '[{"workflow_runs":[]}]' : '[{"workflow_runs":';
      },
    });
    if (recover) assert.deepEqual(await request, [{workflow_runs: []}]);
    else await assert.rejects(request, SyntaxError);
    assert.equal(calls, 3);
    assert.deepEqual(waits, [1000, 2000]);
  }
});
test('resuming publication reuses matching GitHub digests and fully verified Cloudflare bytes', async t => {
  const f = fixture(t), first = f.create();
  await first.github(f.file, true); await first.mirror(f.file, true);
  assert.equal(first.report.github_uploaded, 1); assert.equal(first.report.cloudflare_uploaded, 1);
  const before = f.calls.length, resumed = f.create();
  await resumed.github(f.file, true); await resumed.mirror(f.file, true);
  assert.equal(resumed.report.github_reused, 1); assert.equal(resumed.report.cloudflare_reused, 1);
  assert.ok(!f.calls.slice(before).some(c => c.args.includes('put-object') || c.args.includes('upload')));
  const reads = f.calls.slice(before).filter(c => c.program === 'curl');
  assert.equal(reads.length, 1);
  assert.equal(new URL(reads[0].args.at(-1)).search, '');
});
test('verification after a new immutable upload bypasses a cached missing response', async t => {
  const f = fixture(t, 'cached-miss'), transfer = f.create();
  await transfer.mirror(f.file, true);
  assert.equal(transfer.report.cloudflare_uploaded, 1);
  const reads = f.calls.filter(c => c.program === 'curl');
  assert.equal(reads.length, 2);
  assert.equal(new URL(reads[0].args.at(-1)).search, '');
  assert.match(new URL(reads[1].args.at(-1)).search, /^\?verify=\d+$/);
  assert.deepEqual(f.waits, []);
});
for (const backend of ['github', 'cloudflare']) {
  test(`a lost ${backend} upload response reconciles remote bytes before another write`, async t => {
    const f = fixture(t, `${backend}-response`), transfer = f.create();
    await transfer[backend === 'github' ? 'github' : 'mirror'](f.file, true);
    assert.equal(f.calls.filter(c => c.args.includes('upload') || c.args.includes('put-object')).length, 1);
    assert.deepEqual(f.waits, [1000]);
  });
}
test('a transient edge failure retries once and does not reupload a valid object', async t => {
  const f = fixture(t, 'edge-503');
  f.cloudflare.set(path.basename(f.file), fs.readFileSync(f.file));
  await f.create().mirror(f.file, true);
  assert.deepEqual(f.waits, [1000]);
  assert.ok(!f.calls.some(c => c.args.includes('put-object')));
});
test('corrupt objects and credential failures exhaust retries without committing manifests', async t => {
  for (const failure of ['checksum', 'credentials']) {
    const f = fixture(t, failure);
    if (failure === 'checksum') f.cloudflare.set(path.basename(f.file), Buffer.from('corrupt'));
    await assert.rejects(f.create().mirror(f.file, true), /Checksum|AccessDenied/);
    assert.deepEqual(f.waits, [1000, 2000]);
    assert.equal(f.calls.filter(c => c.args.includes('put-object')).length, failure === 'checksum' ? 0 : 3);
  }
});
test('mutable manifests are replaced only when their bytes differ', async t => {
  const f = fixture(t), transfer = f.create();
  f.cloudflare.set(path.basename(f.file), Buffer.from('previous'));
  await transfer.mirror(f.file, false);
  await transfer.mirror(f.file, false);
  assert.equal(f.calls.filter(c => c.args.includes('put-object')).length, 1);
  assert.ok(f.calls.filter(c => c.program === 'curl').every(c => new URL(c.args.at(-1)).search.startsWith('?verify=')));
});
test('recovery is bounded per operation and by a shared job budget', async () => {
  const waits = [], retry = retryPolicy({ budget: 3, wait: async ms => waits.push(ms) });
  let calls = 0;
  await assert.rejects(retry('persistent outage', async () => { calls++; throw httpError(503, 'outage'); }));
  assert.equal(calls, 3);
  let attempts = 0;
  await retry('temporary outage', async () => { if (!attempts++) throw httpError(502, 'outage'); });
  calls = 0;
  await assert.rejects(retry('budget exhausted', async () => { calls++; throw httpError(503, 'outage'); }));
  assert.equal(calls, 1);
  assert.deepEqual(waits, [1000, 2000, 1000]);
  for (const status of [400, 401, 403, 404, 422]) assert.equal(httpError(status, 'test').transient, true);
  for (const status of [408, 429, 500, 502, 503, 504, 520, 522, 523, 524]) assert.equal(httpError(status, 'test').transient, true);
});
test('retry backoff respects a bounded server delay', async () => {
  const waits = [], retry = retryPolicy({ attempts: 3, delay: 1000, wait: async pause => waits.push(pause) });
  let calls = 0;
  await retry('rate limit', async () => {
    if (++calls < 3) throw Object.assign(httpError(429, 'Rate limited'), { retryAfterMs: calls === 1 ? 5000 : 90000 });
  });
  assert.deepEqual(waits, [5000, 30000]);
});

test('Cloudflare body recovery is bounded, resumes authenticated bytes, and fails safely', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-cloudflare-retry-'));
  const file = path.join(directory, 'pack.tar.zst'), bytes = Buffer.from('0123456789abcdef');
  fs.writeFileSync(file, bytes);
  let mode, requests;
  const server = http.createServer((request, response) => {
    requests.push(request.headers.range || '');
    const offset = Number((request.headers.range || '').match(/bytes=(\d+)-/)?.[1] || 0);
    const attempt = requests.length;
    if (mode === 'permanent') { response.writeHead(403); response.end(); return; }
    if (mode === 'transient' && attempt < 3) { response.writeHead(attempt === 1 ? 524 : 503); response.end(); return; }
    const resumed = offset > 0 && mode !== 'range-ignored';
    const start = resumed ? offset : 0;
    response.writeHead(resumed ? 206 : 200, {
      'Content-Length': String(bytes.length - start),
      ...(resumed ? { 'Content-Range': `bytes ${mode === 'bad-range' ? 0 : start}-${bytes.length - 1}/${bytes.length}` } : {}),
      'CF-Ray': 'fixture-IAD',
    });
    if (mode === 'corrupt') { response.end(Buffer.alloc(bytes.length, 120)); return; }
    if (['resume', 'range-ignored', 'bad-range', 'exhausted'].includes(mode) &&
        (attempt === 1 || (mode === 'resume' && attempt === 2) || mode === 'exhausted')) {
      response.write(bytes.subarray(start, start + 4)); return;
    }
    response.end(bytes.subarray(start));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    fs.rmSync(directory, { recursive: true, force: true });
  });
  for (mode of ['resume', 'range-ignored', 'bad-range', 'corrupt', 'permanent', 'transient', 'exhausted']) {
    requests = [];
    const waits = [], cloudflareRetry = retryPolicy({ attempts: 3, budget: 12, delay: 1000,
      wait: async pause => waits.push(pause) });
    const run = (program, args) => {
      if (program === 'aws') { assert.ok(args.includes('head-object'), 'a failed read must never cause an upload'); return '{}'; }
      assert.equal(program, 'curl');
      const local = [...args];
      local[local.indexOf('--proto') + 1] = '=http';
      local[local.indexOf('--proto-redir') + 1] = '=http';
      local[local.indexOf('--max-time') + 1] = '0.15';
      local[local.length - 1] = `http://127.0.0.1:${server.address().port}/pack.tar.zst`;
      return command(program, local);
    };
    const transfer = transfers({ directory, run, cloudflareRetry });
    const work = transfer.mirror(file, true);
    if (mode === 'bad-range') await assert.rejects(work, /Invalid Content-Range/);
    else if (mode === 'corrupt') await assert.rejects(work, /Checksum\/size mismatch/);
    else if (mode === 'permanent') await assert.rejects(work, /HTTP 403/);
    else if (mode === 'exhausted') await assert.rejects(work, /curl exited 28/);
    else { await work; assert.equal(transfer.report.cloudflare_reused, 1); }
    if (mode === 'resume') {
      assert.deepEqual(requests, ['', 'bytes=4-', 'bytes=8-']);
      assert.equal(transfer.report.reads.at(-1).assembled_bytes, bytes.length);
      assert.equal(transfer.report.reads.at(-1).verified, true);
    }
    if (mode === 'transient' || mode === 'resume' || mode === 'exhausted') assert.deepEqual(waits, [1000, 2000]);
    if (['bad-range', 'corrupt', 'permanent'].includes(mode)) { assert.equal(requests.length, 3); assert.deepEqual(waits, [1000, 2000]); }
    assert.ok(requests.length <= 3);
    assert.ok(!fs.readdirSync(directory).some(name => name.startsWith('verify-')), 'failed and successful operations clean partial files');
  }
});
test('process diagnostics retain errors while every failure remains eligible for bounded retry', async () => {
  for (const [message, transient] of [['HTTP 503: service unavailable', true], ['AccessDenied: no permission', true],
    ['Connection was closed before we received a valid response from endpoint URL', true],
    ['InternalError: internal connectivity issue', true], ['SSL certificate verification failed', true]]) {
    await assert.rejects(command(process.execPath, ['-e', 'process.stderr.write(process.argv[1]);process.exit(1)', message]),
      error => Boolean(error.transient) === transient && error.message.includes(message));
  }
});
test('a real stalled HTTP body retains timing and partial-byte diagnostics without response secrets', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-read-diagnostic-'));
  const headers = path.join(directory, 'headers'), downloaded = path.join(directory, 'body');
  const server = http.createServer((_request, response) => {
    response.writeHead(200, { 'Content-Length': '100', 'CF-Ray': '123456-IAD', 'CF-Cache-Status': 'MISS',
      'Set-Cookie': 'secret-cookie', Location: 'https://example.invalid/?token=secret' });
    response.write('partial');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(directory, { recursive: true, force: true });
  });
  await assert.rejects(command('curl', ['-q', '-sS', '--max-time', '0.3', '--output', downloaded, '--dump-header', headers,
    '--write-out', '%{http_code}\n%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{http_version} %{remote_ip}',
    `http://127.0.0.1:${server.address().port}`]), error => {
    assert.ok(error.transient);
    assert.ok(!Object.keys(error).includes('output'));
    const diagnostic = readDiagnostic(error.output, headers, downloaded);
    assert.equal(diagnostic.http_status, 200);
    assert.equal(diagnostic.saved_bytes, 7);
    assert.equal(diagnostic.received_bytes, 7);
    assert.ok(diagnostic.total_seconds >= 0.29);
    assert.ok(diagnostic.first_byte_seconds < diagnostic.total_seconds);
    assert.deepEqual(diagnostic.headers, { 'content-length': '100', 'cf-ray': '123456-IAD', 'cf-cache-status': 'MISS' });
    assert.doesNotMatch(JSON.stringify(diagnostic), /secret|token|cookie|example/);
    return true;
  });
});
test('diagnostics use only the final HTTP response and reject untrusted header characters', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-read-headers-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const headers = path.join(directory, 'headers');
  fs.writeFileSync(headers, 'HTTP/1.1 302 Found\r\nCF-Ray: earlier-IAD\r\nLocation: secret\r\n\r\n' +
    'HTTP/2 200\r\nContent-Length: 7\r\nCF-Ray: bad\u001b[31mheader\r\n');
  assert.deepEqual(readDiagnostic('200', headers, path.join(directory, 'missing')),
    { http_status: 200, saved_bytes: 0, headers: { 'content-length': '7' } });
});
