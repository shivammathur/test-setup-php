const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { execFileSync } = require('node:child_process');
const { prefetch, download, digest, key, validateEntry, validateContext, safePath, inspectTree, packEnvironment, relocateResources, phpApi, prepareArchive, movePrepared, runtimeContext } = require('../../installer/install-extensions.cjs');
const { unchanged, freshnessReason, compatibilityMatrix, versionBatches, dispatch, publish, validatePublishRun, validatePublishedPHP } = require('../../release/extension-packs.cjs');
const { copyRuntime } = require('../../build/extension-pack.cjs');
const { buildMatrix } = require('../../release/extension-batches.cjs');

const context = { php_version: '8.4', build: 'release', thread_safety: 'nts', architecture: 'arm64' };
test('publication recovery accepts only completed main builds with every compatibility job passing', async () => {
  const source = { status: 'completed', conclusion: 'failure', head_branch: 'main', run_attempt: 1,
    head_repository: { full_name: 'shivammathur/php-darwin' }, path: '.github/workflows/cache-extensions.yml' };
  const jobs = ['imagick / PHP 8.4 / release-nts / arm64', 'Test PHP 8.4 release-nts on macos-26', 'publish']
    .map(name => ({ name, status: 'completed', conclusion: name === 'publish' ? 'failure' : 'success' }));
  const run = (_program, args) => JSON.stringify(args.includes('--paginate') ? [{ jobs }] : source);
  await validatePublishRun('123', run);
  for (const name of ['head_branch', 'path']) {
    const previous = source[name]; source[name] = 'untrusted';
    await assert.rejects(validatePublishRun('123', run)); source[name] = previous;
  }
  for (const job of jobs.slice(0, 2)) {
    job.conclusion = 'failure'; await assert.rejects(validatePublishRun('123', run)); job.conclusion = 'success';
  }
  source.status = 'in_progress'; await assert.rejects(validatePublishRun('123', run));
  await assert.rejects(validatePublishRun('../invalid', run));
});
test('publication-only recovery requires trusted main and every recovery gate including exact archive selection', async () => {
  const source = { status: 'completed', head_branch: 'main', run_attempt: 1,
    head_repository: { full_name: 'shivammathur/php-darwin' }, path: '.github/workflows/recover-extensions.yml' };
  const selection = { name: 'Verify the publication contains exactly the tested variants', conclusion: 'success' };
  const jobs = [
    { name: 'plan', status: 'completed', conclusion: 'success' },
    { name: 'reuse (8.4, arm64)', status: 'completed', conclusion: 'success' },
    { name: 'Test PHP 8.4 on macos-15', status: 'completed', conclusion: 'skipped' },
    { name: 'publish', status: 'completed', conclusion: 'failure', steps: [selection] },
  ];
  const run = (_program, args) => JSON.stringify(args.includes('--paginate') ? [{ jobs }] : source);
  await validatePublishRun('123', run);
  jobs[2].conclusion = 'success';
  await validatePublishRun('123', run);
  for (const job of jobs.slice(0, 3)) {
    const previous = job.conclusion;
    for (const conclusion of ['failure', 'cancelled', null]) {
      job.conclusion = conclusion;
      await assert.rejects(validatePublishRun('123', run), /Source recovery/);
    }
    job.conclusion = previous;
  }
  selection.conclusion = 'skipped';
  await assert.rejects(validatePublishRun('123', run), /Source recovery/);
  selection.conclusion = 'success';
  for (const field of ['head_branch', 'path']) {
    const previous = source[field]; source[field] = 'untrusted';
    await assert.rejects(validatePublishRun('123', run), /Untrusted/); source[field] = previous;
  }
  source.head_repository.full_name = 'other/php-darwin';
  await assert.rejects(validatePublishRun('123', run), /Untrusted/);
});
test('publication requires the current PHP release and exact nightly source for every variant', async t => {
  const metadata = { ...entry('imagick'), php_src_commit: 'a'.repeat(40), php_semver: '8.4.26-dev' };
  const current = { schema: 1, php_version: '8.4', php_semver: '8.4.26', php_src_commit: metadata.php_src_commit, assets: [context] };
  let manifest = current, status = 200, reads = 0;
  t.mock.method(globalThis, 'fetch', async url => {
    assert.match(url, /\/php-8\.4\/php-8\.4-manifest\.json$/);
    reads++;
    return Response.json(manifest, { status });
  });
  await validatePublishedPHP([metadata, { ...metadata, name: 'mongodb' }]);
  assert.equal(reads, 1, 'read each PHP release once per batch');
  for (const change of [{ php_src_commit: 'b'.repeat(40) }, { php_src_commit: undefined },
    { php_semver: '8.4.27' }, { assets: [{ ...context, thread_safety: 'zts' }] }]) {
    manifest = { ...current, ...change };
    await assert.rejects(validatePublishedPHP([metadata]), /refusing stale extension publication/);
  }
  for (const change of [{ schema: 2 }, { php_version: '8.5' }, { php_semver: undefined }, { assets: null }]) {
    manifest = { ...current, ...change };
    await assert.rejects(validatePublishedPHP([metadata]), /Invalid published PHP/);
  }
  manifest = { ...current, php_src_commit: undefined };
  await validatePublishedPHP([entry('imagick')]);
  manifest.php_semver = '8.4.27';
  await assert.rejects(validatePublishedPHP([entry('imagick')]), /refusing stale extension publication/);
  status = 404;
  await assert.rejects(validatePublishedPHP([metadata]), /HTTP 404/);
});
test('publication verifies bytes and current PHP before committing manifests with bounded retries', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-publish-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  for (const name of ['CF_R2_AWS_ACCESS_KEY_ID', 'CF_R2_AWS_SECRET_ACCESS_KEY', 'CF_R2_AWS_S3_ENDPOINT']) {
    const previous = process.env[name]; process.env[name] = 'fixture';
    t.after(() => { if (previous === undefined) delete process.env[name]; else process.env[name] = previous; });
  }
  let failure, baseReads;
  t.mock.method(globalThis, 'fetch', async url => {
    if (url.endsWith('/php-8.4-manifest.json')) {
      baseReads++;
      return Response.json({ schema: 1, php_version: '8.4', assets: [context],
        php_semver: failure === 'stale' || (failure === 'php-changed' && baseReads > 1) ? '8.4.27' : '8.4.26' });
    }
    return new Response('', { status: url.includes('api.github.com') ? 200 : 404 });
  });
  const metadata = entry('imagick');
  fs.writeFileSync(path.join(directory, 'pack.json'), JSON.stringify(metadata));
  fs.writeFileSync(path.join(directory, metadata.file), 'imagick');
  fs.writeFileSync(path.join(directory, 'validation.txt'), JSON.stringify({ name: metadata.name, sha256: metadata.sha256,
    install_seconds: 52, php_preserved: true, services_preserved: true }));
  for (failure of ['', 'stale', 'php-changed', 'upload', 'timeout', 'checksum', '404']) {
    baseReads = 0;
    const calls = [], uploaded = new Map();
    const run = async (program, args, options) => {
      await new Promise(resolve => setImmediate(resolve));
      calls.push({ program, args });
      if (program === 'gh' && args[0] === 'api') return JSON.stringify(args.includes('--paginate') ? [[]] : { id: 1 });
      if (program === 'aws' && args.includes('put-object')) {
        assert.equal(options.env.AWS_MAX_ATTEMPTS, '1');
        const file = args[args.indexOf('--body') + 1];
        assert.equal(args[args.indexOf('--key') + 1], `extensions/${path.basename(file)}`);
        if (failure === 'upload') throw new Error('upload rejected');
        uploaded.set(path.basename(file), fs.readFileSync(file));
      } else if (program === 'aws') return JSON.stringify({ ContentLength: 7, ETag: 'fixture' });
      else if (program === 'curl') {
        assert.equal(args[args.indexOf('--max-time') + 1], '45');
        assert.ok(!args.includes('--retry'));
        const name = path.basename(new URL(args.at(-1)).pathname);
        if (!uploaded.has(name)) return '404';
        if (failure === 'timeout') throw new Error('curl exited 28');
        fs.writeFileSync(args[args.indexOf('--output') + 1], failure === 'checksum' ? 'corrupt' : uploaded.get(name));
        return failure === '404' ? '404' : '200';
      }
      return '';
    };
    if (failure) {
      await assert.rejects(publish(directory, { run }), /upload rejected|curl exited 28|Checksum\/size mismatch|HTTP 404|refusing stale extension publication/);
      if (failure === 'stale') assert.equal(calls.length, 0, 'reject stale packs before any external writes');
      assert.equal(calls.filter(call => call.program === 'aws' && call.args.includes('put-object')).length, failure === 'stale' ? 0 : ['upload', '404'].includes(failure) ? 3 : 1);
      assert.ok(!calls.some(call => call.args.some(arg => arg.endsWith('-manifest.json'))));
    } else {
      await publish(directory, { run });
      assert.equal(baseReads, 2, 'recheck PHP after archive transfers');
      assert.deepEqual(calls.filter(call => call.program === 'gh' && call.args[0] === 'release').map(call => path.basename(call.args[3])),
        [metadata.file, 'extensions-8.4-manifest.json', 'install-extensions.cjs']);
      const manifestUpload = calls.findIndex(call => call.program === 'aws' && call.args.some(arg => arg.endsWith('-manifest.json')));
      const archiveCheck = calls.findIndex(call => call.program === 'curl');
      assert.ok(manifestUpload > archiveCheck);
    }
  }
});
test('all publication failures preserve completed versions and do not publish an incomplete version', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-independent-publish-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  for (const name of ['CF_R2_AWS_ACCESS_KEY_ID', 'CF_R2_AWS_SECRET_ACCESS_KEY', 'CF_R2_AWS_S3_ENDPOINT', 'EXTENSION_PUBLISH_REPORT']) {
    const previous = process.env[name];
    process.env[name] = name === 'EXTENSION_PUBLISH_REPORT' ? path.join(directory, 'report.txt') : 'fixture';
    t.after(() => { if (previous === undefined) delete process.env[name]; else process.env[name] = previous; });
  }
  for (const php_version of ['8.3', '8.4', '8.5']) for (const name of php_version === '8.4' ? ['imagick', 'memcached'] : ['imagick']) {
    const metadata = { ...entry(name), php_version, php_semver: `${php_version}.26` };
    metadata.file = `${key(metadata)}-${metadata.sha256}.tar.zst`;
    const location = path.join(directory, key(metadata));
    fs.mkdirSync(location);
    fs.writeFileSync(path.join(location, 'pack.json'), JSON.stringify(metadata));
    fs.writeFileSync(path.join(location, metadata.file), name);
    fs.writeFileSync(path.join(location, 'validation.txt'), JSON.stringify({ name, sha256: metadata.sha256,
      install_seconds: 52, php_preserved: true, services_preserved: true }));
  }
  t.mock.method(globalThis, 'fetch', async url => {
    const match = url.match(/\/php-(8\.[345])-manifest.json$/);
    if (match) return Response.json({ schema: 1, php_version: match[1], php_semver: `${match[1]}.26`,
      assets: [{ ...context, php_version: match[1] }] });
    return new Response('', { status: url.includes('api.github.com') ? 200 : 404 });
  });
  for (const transient of [true, false]) {
    const calls = [], uploaded = new Map();
    const run = async (program, args) => {
      calls.push({ program, args });
      if (program === 'gh' && args[0] === 'api') return JSON.stringify(args.includes('--paginate') ? [[]] : { id: 1 });
      if (program === 'aws' && args.includes('put-object')) {
        const file = args[args.indexOf('--body') + 1];
        uploaded.set(path.basename(file), fs.readFileSync(file));
      } else if (program === 'aws') return '{}';
      else if (program === 'curl') {
        const name = path.basename(new URL(args.at(-1)).pathname);
        if (!uploaded.has(name)) return '404';
        if (name.startsWith('memcached-8.4-')) throw Object.assign(new Error('stalled archive'), { transient });
        fs.writeFileSync(args[args.indexOf('--output') + 1], uploaded.get(name));
        return '200';
      }
      return '';
    };
    await assert.rejects(publish(directory, { run, retry: async (_label, work) => work() }), /stalled archive/);
    const report = JSON.parse(fs.readFileSync(process.env.EXTENSION_PUBLISH_REPORT));
    assert.equal(report.success, false);
    assert.deepEqual(report.published_versions, ['8.3', '8.5']);
    assert.deepEqual(report.remaining_versions, ['8.4']);
    assert.deepEqual(report.failed_versions.map(item => item.php_version), ['8.4']);
    const manifests = calls.filter(call => call.program === 'gh' && call.args[0] === 'release')
      .map(call => path.basename(call.args[3])).filter(name => name.endsWith('-manifest.json'));
    assert.deepEqual(manifests, ['extensions-8.3-manifest.json', 'extensions-8.5-manifest.json']);
    assert.ok(!calls.some(call => call.args.some(arg => arg.endsWith('install-extensions.cjs'))));
  }
});
test('scheduled batches cover every configured PHP version within both matrix limits', () => {
  const versions = fs.readFileSync(path.resolve(__dirname, '../../../conf/versions'), 'utf8').split('\n')
    .filter(line => /^(stable|nightly) /.test(line)).map(line => line.split(' ')[1]);
  const batches = versionBatches();
  assert.deepEqual(batches.flat(), versions);
  for (const batch of batches) {
    const entries = batch.flatMap(php_version => ['release', 'debug'].flatMap(build => ['nts', 'zts'].flatMap(thread_safety =>
      ['arm64', 'x86_64'].flatMap(architecture => ['imagick', 'mongodb', 'memcached'].map(name =>
        ({ php_version, build, thread_safety, architecture, name }))))));
    entries.forEach(validateContext);
    assert.ok(buildMatrix(entries).include.length <= 256);
    assert.ok(compatibilityMatrix(entries).include.length <= 256);
  }
  for (const version of ['5.5', '7.5', '8.8', '9.0']) {
    assert.throws(() => versionBatches(version), /Unsupported/);
    assert.throws(() => validateContext({ ...context, php_version: version }), /Unsupported/);
  }
});
test('installer-only publication uploads only the installer and inventories retention', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-installer-publish-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  for (const name of ['CF_R2_AWS_ACCESS_KEY_ID', 'CF_R2_AWS_SECRET_ACCESS_KEY', 'CF_R2_AWS_S3_ENDPOINT']) {
    const previous = process.env[name]; process.env[name] = 'fixture';
    t.after(() => { if (previous === undefined) delete process.env[name]; else process.env[name] = previous; });
  }
  t.mock.method(globalThis, 'fetch', async url => {
    assert.match(url, /\/releases\/tags\/extensions$/);
    return new Response('', { status: 200 });
  });
  let uploaded;
  const writes = [];
  await publish(directory, { run: async (program, args) => {
    if (program === 'gh' && args[0] === 'api') return JSON.stringify(args.includes('--paginate') ? [[]] : { id: 1 });
    if (program === 'aws' && args.includes('list-objects-v2')) return JSON.stringify({Contents: []});
    if (program === 'aws') {
      writes.push(args[args.indexOf('--key') + 1]);
      uploaded = fs.readFileSync(args[args.indexOf('--body') + 1]);
    } else if (program === 'curl') {
      assert.match(args.at(-1), /\/install-extensions\.cjs\?verify=/);
      if (!uploaded) return '404';
      fs.writeFileSync(args[args.indexOf('--output') + 1], uploaded);
      return '200';
    } else if (program === 'gh') writes.push(path.basename(args[3]));
    else assert.fail(`Unexpected publication command ${program}`);
    return '';
  } });
  assert.deepEqual(writes, ['extensions/install-extensions.cjs', 'install-extensions.cjs']);
});
test('follow-up batches start only after a successful prerequisite', async () => {
  const calls = [];
  let ready = false;
  const run = (_program, args) => {
    calls.push(args);
    if (args[0] === 'api') return JSON.stringify({ status: ready ? 'completed' : 'in_progress', conclusion: ready ? 'success' : null });
    assert.ok(ready);
  };
  await dispatch({ afterRun: '123', run, wait: async delay => { assert.equal(delay, 60000); ready = true; } });
  assert.equal(calls.filter(args => args[0] === 'workflow').length, 1);
  for (const conclusion of ['failure', 'cancelled', 'timed_out']) {
    await assert.rejects(dispatch({ afterRun: '123', run: (_program, args) => {
      assert.equal(args[0], 'api');
      return JSON.stringify({ status: 'completed', conclusion });
    } }), /Prerequisite run/);
  }
});
test('read the module API from the installed PHP headers using supported php-config options', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-php-api-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.mkdirSync(path.join(directory, 'Zend'));
  fs.writeFileSync(path.join(directory, 'Zend/zend_modules.h'), '#define ZEND_MODULE_API_NO 20240924\n');
  const config = path.join(directory, 'php-config');
  fs.writeFileSync(config, '#!/bin/sh\n[ "$1" = --include-dir ] || exit 1\ndirname "$0"\n', { mode: 0o755 });
  assert.equal(phpApi(config), '20240924');
  fs.writeFileSync(path.join(directory, 'Zend/zend_modules.h'), 'invalid');
  assert.throws(() => phpApi(config), /Missing PHP module API/);
});
function entry(name, content = Buffer.from(name)) {
  const metadata = { ...context, name, schema: 1, sha256: digest(content), inputs_sha256: '1'.repeat(64),
    php_api: '20240924', php_semver: '8.4.26', minimum_macos: 14, bytes: content.length };
  metadata.file = `${key(metadata)}-${metadata.sha256}.tar.zst`;
  return metadata;
}

test('extension context uses php-config for version and variant without starting PHP', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'php-config-context-'));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  const config = path.join(directory, 'php-config');
  fs.mkdirSync(path.join(directory, 'Zend'));
  fs.writeFileSync(path.join(directory, 'Zend/zend_modules.h'), '#define ZEND_MODULE_API_NO 20260925\n');
  for (const version of ['8.7.0-dev', '8.7.0alpha1', '8.7.0beta2', '8.7.0RC1', '8.7.0']) for (const flags of ['', '--enable-debug', '--enable-zts', '--enable-debug --enable-maintainer-zts']) {
    fs.writeFileSync(config, `#!/bin/sh\ncase "$1" in\n--version) echo ${version};;\n--include-dir) dirname "$0";;\n--extension-dir) echo /opt/homebrew/lib/php/pecl;;\n--configure-options) echo "${flags}";;\n*) exit 1;;\nesac\n`, {mode: 0o755});
    const context = runtimeContext(config, '/must/not/run/php');
    assert.equal(context.php_version, '8.7');
    assert.equal(context.build, flags.includes('debug') ? 'debug' : 'release');
    assert.equal(context.thread_safety, flags.includes('zts') ? 'zts' : 'nts');
  }
});
async function fixture(t, handler) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-unit-'));
  const server = http.createServer(handler);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(directory, { recursive: true, force: true });
  });
  return { directory, url: `http://127.0.0.1:${server.address().port}` };
}

test('retired archives refresh the manifest once and install the replacement with its own digest', async t => {
  const old = entry('imagick', Buffer.from('old')), next = entry('imagick', Buffer.from('new'));
  let refreshed = 0, oldReads = 0;
  const {directory, url} = await fixture(t, (req, res) => {
    if (req.url.startsWith('/extensions-8.4-manifest.json')) {
      const fresh = req.url.includes('?refresh=');
      if (fresh) refreshed++;
      return res.end(JSON.stringify({schema: 1, assets: [fresh ? next : old]}));
    }
    if (req.url === '/' + old.file) {oldReads++; res.writeHead(404); return res.end();}
    if (req.url === '/' + next.file) return res.end('new');
    res.writeHead(404); res.end();
  });
  assert.deepEqual(await prefetch(directory, context, ['imagick'], {bases: [url], prepare: async () => {}}), ['imagick']);
  assert.equal(refreshed, 1); assert.equal(oldReads, 3);
  assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'imagick.json'))).sha256, next.sha256);
  assert.equal(fs.readFileSync(path.join(directory, next.file), 'utf8'), 'new');
});
test('all requested packs download concurrently, with no unrequested downloads', async t => {
  const names = ['imagick', 'mongodb', 'memcached'];
  const assets = names.map(name => entry(name));
  const pending = [];
  const requested = [];
  const { directory, url } = await fixture(t, (req, res) => {
    requested.push(req.url);
    if (req.url.endsWith('.json')) return res.end(JSON.stringify({ schema: 1, assets }));
    const asset = assets.find(item => req.url === '/' + item.file);
    assert.ok(asset);
    pending.push({ res, name: asset.name });
    // Sequential downloads would deadlock; all three requests must arrive.
    if (pending.length === 3) pending.forEach(item => item.res.end(item.name));
  });
  const prepared = [];
  assert.deepEqual(await prefetch(directory, context, names, { bases: [url], prepare: async (root, name) => {
    assert.equal(root, directory);
    prepared.push(name);
    await new Promise(resolve => setImmediate(resolve));
  } }), names);
  assert.deepEqual(prepared.sort(), names.sort());
  assert.equal(requested.length, 4);
  for (const asset of assets) assert.equal(fs.readFileSync(path.join(directory, asset.file), 'utf8'), asset.name);
});
test('healthy extension downloads can take longer than three seconds without failing over', async t => {
  const paths = [];
  const { directory, url } = await fixture(t, (req, res) => {
    paths.push(req.url);
    res.write('go');
    setTimeout(() => res.end('od'), 4000);
  });
  await Promise.all(['manifest.json', 'pack.tar.zst'].map(async name => {
    const destination = path.join(directory, name);
    await download(name, destination, { bases: [url + '/primary', url + '/mirror'],
      sha256: digest('good'), ...(name.endsWith('.zst') ? { bytes: 4 } : {}) });
    assert.equal(fs.readFileSync(destination, 'utf8'), 'good');
    assert.ok(!fs.existsSync(`${destination}.partial`));
  }));
  assert.deepEqual(paths.sort(), ['/primary/manifest.json', '/primary/pack.tar.zst']);
});
test('a checksum failure uses the mirror and never promotes corrupt bytes', async t => {
  const content = Buffer.from('good');
  const paths = [];
  const { directory, url } = await fixture(t, (req, res) => { paths.push(req.url); res.end(req.url.startsWith('/primary/') ? 'evil' : content); });
  await download('pack.tar.zst', path.join(directory, 'pack'), { bases: [url + '/primary', url + '/mirror'], sha256: digest(content), bytes: 4 });
  assert.deepEqual(paths, ['/primary/pack.tar.zst', '/primary/pack.tar.zst', '/primary/pack.tar.zst', '/mirror/pack.tar.zst']);
  assert.equal(fs.readFileSync(path.join(directory, 'pack'), 'utf8'), 'good');
  assert.ok(!fs.existsSync(path.join(directory, 'pack.partial')));
});
test('a missing pack does not discard successfully downloaded packs', async t => {
  const assets = ['imagick', 'mongodb'].map(name => entry(name));
  const { directory, url } = await fixture(t, (req, res) => {
    if (req.url.endsWith('.json')) return res.end(JSON.stringify({ schema: 1, assets }));
    res.end('imagick');
  });
  assert.deepEqual(await prefetch(directory, context, ['imagick', 'memcached'], { bases: [url], prepare: async () => {} }), ['imagick']);
  assert.ok(fs.existsSync(path.join(directory, 'imagick.json')));
  assert.ok(!fs.existsSync(path.join(directory, 'memcached.json')));
});
test('wrong variants and duplicate manifest entries do not download archives', async t => {
  let requests = 0;
  const assets = [entry('imagick'), entry('imagick'), { ...entry('mongodb'), architecture: 'x86_64' }];
  const { directory, url } = await fixture(t, (_req, res) => { requests++; res.end(JSON.stringify({ schema: 1, assets })); });
  assert.deepEqual(await prefetch(directory, context, ['imagick', 'mongodb'], { bases: [url] }), []);
  assert.equal(requests, 1);
});
test('failed preparation leaves other downloaded packs available without retrying', async t => {
  const names = ['imagick', 'mongodb'];
  const assets = names.map(name => entry(name));
  const { directory, url } = await fixture(t, (req, res) => {
    if (req.url.endsWith('.json')) return res.end(JSON.stringify({ schema: 1, assets }));
    res.end(assets.find(item => req.url === '/' + item.file).name);
  });
  const calls = [];
  assert.deepEqual(await prefetch(directory, context, names, { bases: [url], prepare: async (_root, name) => {
    calls.push(name);
    if (name === 'mongodb') throw new Error('fixture extraction failed');
  } }), ['imagick']);
  assert.deepEqual(calls.sort(), names.sort());
  assert.ok(fs.existsSync(path.join(directory, 'imagick.json')));
  assert.ok(!fs.existsSync(path.join(directory, 'mongodb.json')));
});
test('preparation verifies archives and metadata without running PHP or writing the Homebrew prefix', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-prepare-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const source = path.join(directory, 'source');
  fs.mkdirSync(path.join(source, 'modules'), { recursive: true });
  const metadata = { ...entry('imagick'), modules: ['imagick'], relocations: [], environment: {} };
  fs.writeFileSync(path.join(source, 'metadata.json'), JSON.stringify(metadata));
  fs.writeFileSync(path.join(source, 'modules/imagick.so'), 'native module fixture');
  const archive = path.join(directory, 'fixture.tar.zst');
  execFileSync('tar', ['--zstd', '-cf', archive, '-C', source, 'metadata.json', 'modules']);
  const record = { ...metadata, ...entry('imagick', fs.readFileSync(archive)) };
  fs.renameSync(archive, path.join(directory, record.file));
  fs.writeFileSync(path.join(directory, 'imagick.json'), JSON.stringify(record));
  const stage = prepareArchive(directory, 'imagick');
  assert.equal(stage, path.join(directory, `imagick-${record.sha256}.stage`));
  assert.equal(fs.readFileSync(path.join(stage, 'modules/imagick.so'), 'utf8'), 'native module fixture');
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(stage, 'metadata.json'))), metadata);
  assert.equal(fs.readdirSync(directory).filter(name => name.startsWith('.prepare-')).length, 0);
  const bytes = fs.readFileSync(path.join(directory, record.file));
  const served = await fixture(t, (req, res) => {
    res.end(req.url.endsWith('.json') ? JSON.stringify({ schema: 1, assets: [record] }) : bytes);
  });
  assert.deepEqual(await prefetch(served.directory, context, ['imagick'], { bases: [served.url] }), ['imagick']);
  assert.equal(fs.readFileSync(path.join(served.directory, `imagick-${record.sha256}.stage/modules/imagick.so`), 'utf8'), 'native module fixture');
  fs.rmSync(stage, { recursive: true });
  fs.writeFileSync(path.join(directory, record.file), 'corrupt');
  assert.throws(() => prepareArchive(directory, 'imagick'), /changed after download/);
  assert.ok(!fs.existsSync(stage));
});
test('prepared packs move atomically when the temporary directory is on another volume', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-move-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const stage = path.join(directory, 'stage'), destination = path.join(directory, 'installed');
  fs.mkdirSync(stage);
  fs.writeFileSync(path.join(stage, 'module'), 'native module');
  fs.symlinkSync('module', path.join(stage, 'alias'));
  const rename = fs.renameSync;
  const moves = [];
  t.mock.method(fs, 'renameSync', (from, to) => {
    moves.push([from, to]);
    if (from === stage) throw Object.assign(new Error('other volume'), { code: 'EXDEV' });
    assert.equal(fs.readFileSync(path.join(from, 'module'), 'utf8'), 'native module');
    assert.equal(fs.readlinkSync(path.join(from, 'alias')), 'module');
    return rename(from, to);
  });
  movePrepared(stage, destination);
  assert.equal(moves.length, 2);
  assert.equal(fs.readFileSync(path.join(destination, 'alias'), 'utf8'), 'native module');
  assert.ok(!fs.readdirSync(directory).some(name => name.startsWith('.install-')));
});
test('reject unsupported contexts, unsafe archive paths and invalid identities', () => {
  for (const value of ['../escape', '/absolute', 'a/../../b', 'a//b', 'a\nb', 'a\\b']) assert.equal(safePath(value), false);
  assert.equal(safePath('kegs/library/1.0/LICENSE file'), true);
  for (const patch of [{ name: 'invalid' }, { bytes: -1 }, { sha256: 'bad' }, { php_version: '5.4' },
    { architecture: 'other' }, { php_api: 'wrong' }, { file: '../bad.tar.zst' }]) assert.throws(() => validateEntry({ ...entry('imagick'), ...patch }));
});
test('private runtime symlinks must resolve inside the archive', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-links-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.mkdirSync(path.join(directory, 'lib'));
  fs.writeFileSync(path.join(directory, 'lib/a'), 'a');
  fs.symlinkSync('a', path.join(directory, 'lib/b'));
  inspectTree(directory);
  fs.symlinkSync('/etc/passwd', path.join(directory, 'lib/c'));
  assert.throws(() => inspectTree(directory), /Unsafe/);
});
test('only known runtime resource paths can be exported by a pack', () => {
  assert.deepEqual(packEnvironment({ environment: { MAGICK_CONFIGURE_PATH: ['kegs/imagemagick/etc'] } }, '/pack'),
    { MAGICK_CONFIGURE_PATH: '/pack/kegs/imagemagick/etc' });
  assert.throws(() => packEnvironment({ environment: { PATH: ['bin'] } }, '/pack'));
  assert.throws(() => packEnvironment({ environment: { MAGICK_CONFIGURE_PATH: ['../escape'] } }, '/pack'));
  assert.deepEqual(packEnvironment({ environment: { SASL_PATH: ['kegs/cyrus-sasl/lib/sasl2'] } }, '/pack'),
    { SASL_PATH: '/pack/kegs/cyrus-sasl/lib/sasl2' });
});
test('codec descriptors use the installed private runtime directory', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-resources-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.writeFileSync(path.join(directory, 'png.la'), "libdir='@PHP_DARWIN_EXTENSION_ROOT@/kegs/imagemagick/lib/coders'\n");
  relocateResources({ relocations: ['png.la'] }, directory, '/private-pack');
  assert.equal(fs.readFileSync(path.join(directory, 'png.la'), 'utf8'), "libdir='/private-pack/kegs/imagemagick/lib/coders'\n");
  assert.throws(() => relocateResources({ relocations: ['../outside.la'] }, directory, '/private-pack'));
  assert.throws(() => relocateResources({ relocations: ['script.sh'] }, directory, '/private-pack'));
});
test('runtime copies retain licenses and codec descriptors without dangling manual-page links', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-runtime-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const source = path.join(directory, 'source');
  const output = path.join(directory, 'output');
  const files = ['share/man/man3/ASN1.3ssl', 'share/doc/NOTICE.txt', 'share/doc/manual.html',
    'lib/libssl.dylib', 'lib/libssl.a', 'lib/libssl.la', 'lib/ImageMagick/modules-Q16/coders/png.la'];
  for (const file of files) {
    fs.mkdirSync(path.dirname(path.join(source, file)), { recursive: true });
    fs.writeFileSync(path.join(source, file), file);
  }
  fs.symlinkSync('ASN1.3ssl', path.join(source, 'share/man/man3/NOTICEREF_free.3ssl'));
  fs.mkdirSync(path.join(source, 'libexec/gnuman/man1'), { recursive: true });
  fs.symlinkSync('../../../share/man/man3/ASN1.3ssl', path.join(source, 'libexec/gnuman/man1/tool.1'));
  copyRuntime(source, output);
  inspectTree(output);
  assert.ok(fs.existsSync(path.join(output, 'share/doc/NOTICE.txt')));
  assert.ok(fs.existsSync(path.join(output, 'lib/ImageMagick/modules-Q16/coders/png.la')));
  for (const file of ['share/man', 'libexec/gnuman', 'share/doc/manual.html', 'lib/libssl.a', 'lib/libssl.la']) {
    assert.ok(!fs.existsSync(path.join(output, file)));
  }
});
test('freshness tracks software inputs and ignores php-darwin builder revisions', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-freshness-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.writeFileSync(path.join(directory, 'formula.rb'), 'original');
  const metadata = { ...entry('imagick'), builder_sha256: 'a'.repeat(64), php_semver: '8.4.26',
    source_records: [{ repository: 'core', path: 'formula.rb', sha256: digest('original') }] };
  const repositories = { core: directory };
  assert.ok(unchanged(metadata, repositories, { php_semver: '8.4.26' }));
  assert.equal(freshnessReason(metadata, repositories, { php_semver: '8.4.26' }), null);
  assert.equal(freshnessReason(metadata, repositories, { php_semver: '8.4.27' }), 'PHP release changed');
  assert.equal(unchanged(metadata, repositories, { php_semver: '8.4.27' }), false);
  const nightly = { ...metadata, php_version: '8.7', php_semver: '8.7.0-dev', php_src_commit: 'a'.repeat(40) };
  nightly.file = `${key(nightly)}-${nightly.sha256}.tar.zst`;
  assert.ok(unchanged(nightly, repositories, { php_semver: '8.7.0', php_src_commit: nightly.php_src_commit }));
  assert.equal(unchanged(nightly, repositories, { php_semver: '8.7.0', php_src_commit: 'b'.repeat(40) }), false);
  assert.equal(unchanged({ ...metadata, builder_sha256: '0'.repeat(64) }, repositories, { php_semver: '8.4.26' }), true);
  assert.equal(freshnessReason({ ...metadata, builder_sha256: '0'.repeat(64) }, repositories, { php_semver: '8.4.26' }), null);
  fs.writeFileSync(path.join(directory, 'formula.rb'), 'updated dependency');
  assert.equal(unchanged(metadata, repositories, { php_semver: '8.4.26' }), false);
  assert.equal(freshnessReason(metadata, repositories, { php_semver: '8.4.26' }), 'recipe changed: core/formula.rb');
});

test('compatibility covers newer hosts while build jobs validate the build platforms', () => {
  const entries = ['arm64', 'x86_64'].flatMap(architecture => ['imagick', 'mongodb', 'memcached'].map(name =>
    ({ ...context, architecture, name })));
  const { include } = compatibilityMatrix(entries);
  assert.equal(include.length, 3);
  assert.ok(!include.some(item => item.runner === 'macos-15-intel'));
  assert.ok(include.some(item => item.runner === 'macos-26-intel'));
  for (const item of include) assert.deepEqual(item.entries.map(entry => entry.name), ['imagick', 'mongodb', 'memcached']);
});
