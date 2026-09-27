const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { runSetupPhp } = require('../helpers/run-setup-php.cjs');

test('unchanged setup-php runs outside darwin parent paths and cleans up after success or failure', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'php-darwin-action-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'dist'));
  fs.mkdirSync(path.join(root, 'src/scripts'), { recursive: true });
  const script = "const fs = require('fs'); const path = require('path'); const source = path.join(__dirname, '../src/scripts/darwin.sh'); fs.writeFileSync(source.replace('darwin', 'run'), 'generated'); process.exit(Number(process.env.FIXTURE_EXIT || 0));";
  fs.writeFileSync(path.join(root, 'dist/index.js'), script);
  fs.writeFileSync(path.join(root, 'src/scripts/darwin.sh'), 'unchanged');
  assert.equal(runSetupPhp(root), 0);
  let copied;
  assert.equal(runSetupPhp(root, (node, [file], options) => {
    copied = path.dirname(path.dirname(file));
    assert.equal(copied.includes('darwin'), false);
    assert.equal(fs.readFileSync(file, 'utf8'), script);
    assert.equal(options.env.runner, 'github');
    assert.equal(options.env.RUNNER_ENVIRONMENT, 'github-hosted');
    assert.ok(options.env.ImageOS && options.env.ImageVersion);
    assert.equal(options.env.ACT, '');
    assert.equal(options.env.CONTAINER, '');
    return require('node:child_process').spawnSync(node, [file], { ...options, env: { ...options.env, FIXTURE_EXIT: '7' } });
  }), 7);
  assert.equal(fs.existsSync(copied), false);
  assert.equal(fs.existsSync(path.join(root, 'src/scripts/run.sh')), false);
  assert.equal(fs.readFileSync(path.join(root, 'src/scripts/darwin.sh'), 'utf8'), 'unchanged');
});

test('the setup-php hook selects candidate installer bytes and preserves failures without timing instrumentation', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'php-installer-hook-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const candidate = path.join(root, 'candidate.sh');
  fs.writeFileSync(candidate, 'printf "candidate %s %s %s\\n" "$@"\nexit "${FIXTURE_EXIT:-0}"\n');
  const env = {...process.env, BASH_ENV: path.resolve(__dirname, '../helpers/setup-php-installer.sh'),
    repo: 'php-darwin', RUNNER_TEMP: root, PHP_DARWIN_TEST_INSTALLER: candidate};
  const run = (script, patch = {}) => require('node:child_process').spawnSync('bash', ['-c', script],
    {encoding: 'utf8', env: {...env, ...patch}});
  for (const status of [0, 7]) {
    const result = run('bash /tmp/install.sh 8.5 release nts', {FIXTURE_EXIT: String(status)});
    assert.equal(result.status, status, result.stderr);
    assert.match(result.stdout, /candidate 8\.5 release nts/);
  }
  assert.match(fs.readFileSync(path.join(root, 'php-darwin-setup-install.log'), 'utf8'), /candidate 8\.5 release nts/);
  assert.deepEqual(fs.readdirSync(root).sort(), ['candidate.sh', 'php-darwin-setup-install.log']);
  const unrelated = run('bash -c "printf unrelated"');
  assert.equal(unrelated.status, 0, unrelated.stderr);
  assert.equal(unrelated.stdout, 'unrelated');
});
