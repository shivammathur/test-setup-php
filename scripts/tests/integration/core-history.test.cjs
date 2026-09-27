const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

test('CI repairs shallow core history once without changing approved files or local checkouts', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'core-history-'));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  const origin = path.join(directory, 'origin'), core = path.join(directory, 'core');
  fs.mkdirSync(origin);
  const git = (cwd, args) => {
    const result = spawnSync('git', ['-C', cwd, ...args], {encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  git(origin, ['init', '-q']);
  for (let i = 0; i < 3; i++) {
    fs.writeFileSync(path.join(origin, 'formula.rb'), `approved ${i}`);
    git(origin, ['add', '.']);
    git(origin, ['-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', String(i)]);
  }
  git(directory, ['clone', '-q', '--depth=1', `file://${origin}`, core]);
  const head = git(core, ['rev-parse', 'HEAD']);
  fs.writeFileSync(path.join(core, 'formula.rb'), 'preserved runner edit');
  const run = ci => spawnSync('bash', [path.resolve(__dirname, '../../build/ensure-core-history.sh'), core], {
    encoding: 'utf8', env: {...process.env, GITHUB_ACTIONS: ci},
  });
  assert.equal(run('false').status, 0);
  assert.equal(git(core, ['rev-parse', '--is-shallow-repository']), 'true');
  const result = run('true');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(git(core, ['rev-parse', '--is-shallow-repository']), 'false');
  assert.equal(git(core, ['rev-list', '--count', 'HEAD']), '3');
  assert.equal(git(core, ['rev-parse', 'HEAD']), head);
  assert.equal(fs.readFileSync(path.join(core, 'formula.rb'), 'utf8'), 'preserved runner edit');
  git(core, ['remote', 'set-url', 'origin', path.join(directory, 'absent')]);
  assert.equal(run('true').status, 0, 'full history must not require another fetch');
});
