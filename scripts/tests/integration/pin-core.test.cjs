const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

test('pinning discards modified runner formulae while retaining the local dirty-tree guard', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'php-darwin-pin-core-'));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  const core = path.join(directory, 'core'), bin = path.join(directory, 'bin');
  fs.mkdirSync(core); fs.mkdirSync(bin);
  const git = args => {
    const result = spawnSync('git', ['-C', core, ...args], {encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  git(['init', '-q']);
  const formula = path.join(core, 'rustup.rb');
  const commit = value => {
    fs.writeFileSync(formula, value);
    git(['add', '.']);
    git(['-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', value]);
    return git(['rev-parse', 'HEAD']);
  };
  const pinned = commit('approved formula\n');
  const current = commit('runner formula\n');
  fs.writeFileSync(formula, 'runner modification\n');
  fs.writeFileSync(path.join(bin, 'brew'), '#!/bin/sh\ncase "$1" in\n tap) exit 0;;\n --repository) printf "%s\\n" "$PIN_CORE_FIXTURE";;\n *) exit 1;;\nesac\n', {mode: 0o755});
  const run = ci => spawnSync('bash', [path.resolve(__dirname, '../../build/pin-core.sh')], {
    encoding: 'utf8', env: {...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`,
      PIN_CORE_FIXTURE: core, HOMEBREW_CORE_COMMIT: pinned, GITHUB_ACTIONS: ci},
  });
  assert.notEqual(run('false').status, 0);
  assert.equal(git(['rev-parse', 'HEAD']), current);
  assert.equal(fs.readFileSync(formula, 'utf8'), 'runner modification\n');
  const result = run('true');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(git(['rev-parse', 'HEAD']), pinned);
  assert.equal(fs.readFileSync(formula, 'utf8'), 'approved formula\n');
  assert.equal(git(['status', '--porcelain']), '');
});
