const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const { Readable } = require('node:stream');
const { once } = require('node:events');
const { curlRequest, errorDetails } = require('../../lib/release-http.cjs');
const { ReleaseCache } = require('../../cache/source-bottle-releases.cjs');

async function server(t, handle) {
  const instance = http.createServer(handle);
  instance.listen(0, '127.0.0.1');
  await once(instance, 'listening');
  t.after(() => new Promise(resolve => { instance.closeAllConnections(); instance.close(resolve); }));
  return `http://127.0.0.1:${instance.address().port}`;
}

test('curl transfers binary uploads and downloads without changing bytes or headers', async t => {
  const bytes = Buffer.from([0, 255, 10, 13, 34, 92, 128]);
  const url = await server(t, async (request, response) => {
    assert.equal(request.method, 'POST');
    assert.equal(request.headers.authorization, 'Bearer private-test-token');
    assert.equal(request.headers['content-type'], 'application/octet-stream');
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    assert.deepEqual(Buffer.concat(chunks), bytes);
    response.writeHead(201, { 'content-type': 'application/octet-stream', etag: '"verified"' });
    response.end(bytes);
  });
  const response = await curlRequest(url, { method: 'POST', headers: {
    Authorization: 'Bearer private-test-token', 'Content-Type': 'application/octet-stream', 'Content-Length': String(bytes.length),
  }, body: Readable.from([bytes]), signal: AbortSignal.timeout(5000) });
  assert.equal(response.status, 201);
  assert.equal(response.headers.get('etag'), '"verified"');
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes);
});

test('redirects use final response headers and do not forward authorization to another host', async t => {
  const destination = await server(t, (request, response) => {
    assert.equal(request.headers.authorization, undefined);
    response.writeHead(200, { etag: '"final"' });
    response.end('download');
  });
  const source = await server(t, (request, response) => {
    assert.equal(request.headers.authorization, 'Bearer private-test-token');
    response.writeHead(302, { location: destination, etag: '"redirect"' });
    response.end();
  });
  const response = await curlRequest(source.replace('127.0.0.1', 'localhost'), {
    headers: { Authorization: 'Bearer private-test-token' }, signal: AbortSignal.timeout(5000),
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('etag'), '"final"');
  assert.equal(await response.text(), 'download');
});

test('304, 204, and permission failures remain HTTP responses for the retry policy', async t => {
  const url = await server(t, (request, response) => {
    const status = Number(request.url.slice(1));
    assert.equal(request.headers['if-none-match'], '"same"');
    response.writeHead(status, { etag: '"same"' });
    response.end(status === 403 ? 'permission denied' : undefined);
  });
  for (const status of [304, 204, 403]) {
    const response = await curlRequest(`${url}/${status}`, { headers: { 'If-None-Match': '"same"' }, signal: AbortSignal.timeout(5000) });
    assert.equal(response.status, status);
    assert.equal(await response.text(), status === 403 ? 'permission denied' : '');
  }
});

test('HTTP server errors retain normal retries without switching network clients', async () => {
  let calls = 0;
  const cache = new ReleaseCache({ repository: 'shivammathur/php-darwin', token: 'fixture',
    request: async () => new Response(++calls === 1 ? 'unavailable' : 'ok', { status: calls === 1 ? 503 : 200 }),
    fallbackRequest: async () => { throw new Error('HTTP response must not change clients'); }, wait: async () => {}, warn: () => {} });
  assert.equal(await cache.transfer('https://api.github.com/', () => ({}), response => response.text()), 'ok');
  assert.equal(calls, 2);
  assert.equal(cache.useFallback, undefined);
});

test('aborted transfers close curl and remove temporary credential and response files', async t => {
  const existing = new Set(fs.readdirSync(os.tmpdir()).filter(name => name.startsWith('php-darwin-http-')));
  const url = await server(t, () => {});
  await assert.rejects(curlRequest(url, { headers: { Authorization: 'Bearer private-test-token' },
    signal: AbortSignal.timeout(100) }), /abort/i);
  assert.deepEqual(new Set(fs.readdirSync(os.tmpdir()).filter(name => name.startsWith('php-darwin-http-'))), existing);
});

test('a failed Node connection switches subsequent retries and requests to curl', async t => {
  let calls = 0;
  const url = await server(t, async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    assert.equal(Buffer.concat(chunks).toString(), 'fresh upload stream');
    response.writeHead(201); response.end('saved');
  });
  const error = new TypeError('fetch failed', { cause: Object.assign(new Error('Connection timed out'), { code: 'UND_ERR_CONNECT_TIMEOUT' }) });
  const warnings = [], delays = [];
  const cache = new ReleaseCache({ repository: 'shivammathur/php-darwin', token: 'fixture',
    request: async () => { calls++; throw error; }, fallbackRequest: curlRequest,
    wait: async delay => delays.push(delay), warn: message => warnings.push(message) });
  const upload = () => cache.transfer(url, () => ({ method: 'POST', body: Readable.from(['fresh upload stream']) }), response => response.text());
  assert.equal(await upload(), 'saved');
  assert.equal(await upload(), 'saved');
  assert.equal(calls, 1);
  assert.deepEqual(delays, [1000]);
  assert.match(warnings[0], /curl.*UND_ERR_CONNECT_TIMEOUT/);
  assert.match(errorDetails(error), /Connection timed out/);
});
