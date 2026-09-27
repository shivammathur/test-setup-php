const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { key, digest } = require('../../installer/install-extensions.cjs');
const { buildMatrix, testMatrix, variants, reuse, verifyArchive, downloadArtifact } = require('../../release/extension-batches.cjs');
const { batch } = require('../../build/extension-batch.cjs');
const { planRecovery } = require('../../release/extension-recovery.cjs');
const versions = require('../../../conf/extension-packs.json').versions;

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-batches-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return directory;
}
function entry(name = 'mongodb', patch = {}) {
  const result = { schema: 1, name, php_version: '8.4', architecture: 'arm64', build: 'release', thread_safety: 'nts',
    php_api: '20240924', minimum_macos: 14, inputs_sha256: 'a'.repeat(64), bytes: name.length, sha256: digest(name), ...patch };
  result.file = `${key(result)}-${result.sha256}.tar.zst`;
  return result;
}
function writeArchive(folder, metadata) {
  fs.mkdirSync(folder, { recursive: true });
  fs.writeFileSync(path.join(folder, `${key(metadata)}.json`), JSON.stringify(metadata));
  fs.writeFileSync(path.join(folder, metadata.file), metadata.name);
  fs.writeFileSync(path.join(folder, 'validation.txt'), JSON.stringify({ name: metadata.name, sha256: metadata.sha256,
    php_preserved: true, services_preserved: true }));
}
test('all 336 packs use 28 build jobs and 42 compatibility jobs, retaining every variant', () => {
  const entries = versions.flatMap(php_version => ['arm64', 'x86_64'].flatMap(architecture =>
    ['debug', 'release'].flatMap(build => ['nts', 'zts'].flatMap(thread_safety =>
      ['imagick', 'mongodb', 'memcached'].map(name => ({ php_version, architecture, build, thread_safety, name }))))));
  assert.equal(entries.length, 336);
  assert.equal(buildMatrix(entries).include.length, 28);
  const tests = testMatrix(entries).include;
  assert.equal(tests.length, 42);
  assert.ok(tests.every(item => item.runner !== 'macos-latest'));
  assert.equal(buildMatrix(entries).include.filter(item => item.runner === 'macos-15-intel').length, 14);
  assert.equal(tests.filter(item => item.runner === 'macos-26-intel').length, 14);
  for (const job of [...buildMatrix(entries).include, ...tests]) {
    assert.equal(variants(job.entries).length, 4);
    assert.equal(job.entries.length, 12);
    assert.ok(job.entries.every(item => item.php_version === job.php_version && item.architecture === job.architecture));
  }
});
test('Ubuntu reuse downloads each immutable bundle once and selects only independently validated packs', t => {
  const directory = fixture(t), calls = [];
  const selected = ['imagick', 'mongodb'].map(name => ({ ...entry(name), artifact_id: 123, source_run: '456' }));
  const index = reuse(selected, directory, { download: (artifact, folder) => {
    calls.push(artifact.artifact_id);
    for (const metadata of [...selected, entry('memcached')]) writeArchive(path.join(folder, `extension-${key(metadata)}`), metadata);
    fs.writeFileSync(path.join(folder, `extension-${key(entry('memcached'))}`, `${key(entry('memcached'))}.json`), 'interrupted write');
  } });
  assert.deepEqual(calls, [123]);
  assert.equal(index.length, 2);
  assert.ok(!fs.existsSync(path.join(directory, `extension-${key(entry('memcached'))}`)));
  for (const expected of selected) assert.equal(verifyArchive(directory, expected).entry.sha256, expected.sha256);
  assert.throws(() => verifyArchive(directory, { ...selected[0], sha256: 'a'.repeat(64) }), /differs from the recovery index/);
  assert.throws(() => verifyArchive(directory, { ...selected[0], bytes: selected[0].bytes + 1 }), /differs from the recovery index/);
  fs.writeFileSync(path.join(directory, `extension-${key(selected[0])}`, selected[0].file), 'corrupt');
  assert.throws(() => verifyArchive(directory, selected[0]), /Invalid archive bytes/);
});
test('a failed pack does not stop unrelated packs or discard their checkpoint, and PHP preparation is shared', t => {
  const directory = fixture(t);
  const previous = process.env.RUNNER_TEMP; process.env.RUNNER_TEMP = directory;
  t.after(() => { if (previous === undefined) delete process.env.RUNNER_TEMP; else process.env.RUNNER_TEMP = previous; });
  const entries = ['imagick', 'mongodb', 'memcached'].map(name => entry(name));
  const calls = [];
  const run = (program, args, env) => {
    calls.push({ program, args, name: env.EXTENSION_PACK });
    if (args.includes('.github/actions/source-cache/main.cjs')) {
      if (env.EXTENSION_PACK === 'mongodb') throw new Error('Fixture compilation failed');
      writeArchive(env.EXTENSION_PACK_OUTPUT, entry(env.EXTENSION_PACK));
    }
  };
  assert.throws(() => batch(entries, 'build', { run, output: path.join(directory, 'packs'), indexOutput: path.join(directory, 'index') }), /mongodb/);
  assert.equal(calls.filter(call => call.args.includes('scripts/build/prepare-extension-pack.sh')).length, 1);
  assert.equal(calls.filter(call => call.args.includes('scripts/tests/native/extension-pack.test.cjs')).length, 2);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, 'index/entries.json'))).map(item => item.name), ['imagick', 'memcached']);
});
test('pinning core keeps a full checkout updateable on later runner jobs', t => {
  const directory = fixture(t), source = path.join(directory, 'source'), core = path.join(directory, 'core');
  const bin = path.join(directory, 'bin'); fs.mkdirSync(bin);
  const env = { ...process.env, GIT_AUTHOR_NAME: 'Fixture', GIT_AUTHOR_EMAIL: 'fixture@example.test',
    GIT_COMMITTER_NAME: 'Fixture', GIT_COMMITTER_EMAIL: 'fixture@example.test' };
  const git = (...args) => execFileSync('git', args, { env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git('init', source); git('-C', source, 'commit', '--allow-empty', '-m', 'first');
  git('clone', '--no-local', source, core);
  git('-C', source, 'commit', '--allow-empty', '-m', 'second');
  const commit = git('-C', source, 'rev-parse', 'HEAD');
  fs.writeFileSync(path.join(bin, 'brew'), '#!/bin/sh\nprintf "%s\\n" "$CORE_FIXTURE"\n', { mode: 0o755 });
  const previous = process.env.RUNNER_TEMP; process.env.RUNNER_TEMP = directory;
  t.after(() => { if (previous === undefined) delete process.env.RUNNER_TEMP; else process.env.RUNNER_TEMP = previous; });
  batch([entry()], 'build', { output: path.join(directory, 'packs'), indexOutput: path.join(directory, 'index'),
    run: (program, args, buildEnv) => {
      if (args[0] === 'scripts/build/pin-core.sh') execFileSync(program, args, { env: { ...env, PATH: `${bin}:${env.PATH}`,
        CORE_FIXTURE: core, HOMEBREW_CORE_COMMIT: commit }, stdio: 'pipe' });
      if (args.includes('.github/actions/source-cache/main.cjs')) writeArchive(buildEnv.EXTENSION_PACK_OUTPUT, entry());
    } });
  assert.equal(git('-C', core, 'rev-parse', 'HEAD'), commit);
  assert.equal(git('-C', core, 'rev-parse', '--is-shallow-repository'), 'false');
  assert.equal(git('-C', core, 'rev-list', '--count', 'HEAD'), '2');
});
test('grouped recovery accepts passing checkpoints in a failed job but rejects the wrong bundle context', async t => {
  fixture(t);
  const metadata = entry();
  const source = { status: 'completed', head_branch: 'main', run_attempt: 1, head_sha: 'a'.repeat(40),
    head_repository: { full_name: 'shivammathur/php-darwin' }, path: '.github/workflows/cache-extensions.yml' };
  const artifacts = [{ id: 10, name: 'extension-index-built-8.4-arm64' }, { id: 11, name: 'extension-built-8.4-arm64' }];
  const run = (_program, args) => JSON.stringify(args.at(-1).includes('/jobs?') ? [{ jobs: [{ name: 'Cache PHP 8.4 / arm64', conclusion: 'failure' }] }] :
    args.at(-1).includes('/artifacts?') ? [{ artifacts }] : source);
  const download = (artifact, folder) => { assert.equal(artifact.artifact_id, 10); fs.writeFileSync(path.join(folder, 'entries.json'), JSON.stringify([metadata])); };
  const recovered = await planRecovery('123', run, undefined, { download });
  assert.equal(recovered.entries.length, 1);
  assert.equal(recovered.entries[0].artifact_id, 11);
  metadata.architecture = 'x86_64'; metadata.file = `${key(metadata)}-${metadata.sha256}.tar.zst`;
  await assert.rejects(planRecovery('123', run, undefined, { download }), /context mismatch/);
});


test('artifact download retries every failure with fresh output and a three-attempt limit', t => {
  const directory = fixture(t);
  const payload = path.join(directory, 'payload');
  fs.mkdirSync(payload);
  fs.writeFileSync(path.join(payload, 'verified.txt'), 'verified artifact');
  execFileSync('zip', ['-q', path.join(directory, 'fixture.zip'), 'verified.txt'], {cwd: payload});
  const bytes = fs.readFileSync(path.join(directory, 'fixture.zip'));
  for (const mode of ['recover', 'forbidden', 'checksum']) {
    let attempts = 0;
    const waits = [], output = path.join(directory, mode);
    const work = () => downloadArtifact({artifact_id: 42, artifact_digest: `sha256:${digest(bytes)}`}, output, {
      wait: ms => waits.push(ms),
      run: (_program, _args, options) => {
        attempts++;
        fs.writeSync(options.stdio[1], mode === 'checksum' || attempts < 3 ? Buffer.from('partial') : bytes);
        return {status: mode === 'forbidden' || attempts < 2 ? 1 : 0, stderr: 'HTTP 403'};
      }
    });
    if (mode === 'recover') {
      work();
      assert.equal(fs.readFileSync(path.join(output, 'verified.txt'), 'utf8'), 'verified artifact');
    } else assert.throws(work, mode === 'checksum' ? /digest mismatch/ : /403/);
    assert.equal(attempts, 3);
    assert.deepEqual(waits, [1000, 2000]);
    assert.equal(fs.existsSync(path.join(output, 'artifact.zip')), false);
  }
});

test('test mode accepts flattened and grouped artifacts and rejects missing variants without build preparation', t => {
  const directory = fixture(t), previous = process.env.RUNNER_TEMP;
  process.env.RUNNER_TEMP = directory;
  t.after(() => { if (previous === undefined) delete process.env.RUNNER_TEMP; else process.env.RUNNER_TEMP = previous; });
  for (const grouped of [false, true]) {
    const output = path.join(directory, String(grouped)), selected = entry();
    writeArchive(grouped ? path.join(output, `extension-${key(selected)}`) : output, selected);
    let validated = 0;
    const run = (_program, args, env) => {
      if (args[0] === 'scripts/build/prepare-extension-pack.sh') assert.equal(args[1], 'test');
      else {
        assert.equal(args[0], 'scripts/tests/native/extension-pack.test.cjs');
        assert.equal(fs.existsSync(path.join(env.EXTENSION_PACK_OUTPUT, 'validation.txt')), false);
        validated++;
        writeArchive(env.EXTENSION_PACK_OUTPUT, selected);
      }
    };
    batch([selected], 'test', {run, output});
    assert.equal(validated, 1);
    assert.throws(() => batch([{...selected, thread_safety: 'zts'}], 'test', {run, output}), /Failed test variants/);
  }
});
