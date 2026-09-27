const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {test} = require('node:test');

function fixture(t, ci = true) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'php-darwin-untap-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const bin = path.join(root, 'bin'), repository = path.join(root, 'Homebrew');
  const tap = path.join(repository, 'Library/Taps/example/homebrew-unused');
  fs.mkdirSync(bin);
  fs.mkdirSync(tap, {recursive: true});
  fs.mkdirSync(path.join(repository, 'Library/Homebrew'));
  fs.writeFileSync(path.join(bin, 'brew'), `#!/bin/bash
case "$1" in
  tap) printf 'homebrew/core\\nshivammathur/php\\nexample/unused\\n' ;;
  --repository) printf '%s\\n' "$TEST_REPOSITORY" ;;
  untap)
    printf '%s\\n' "$*" >> "$TEST_ROOT/calls"
    [ -f "$TEST_ROOT/repaired" ] || { echo 'permission denied' >&2; exit 1; }
    ;;
  *) exit 99 ;;
esac
`, {mode: 0o755});
  fs.writeFileSync(path.join(bin, 'sudo'), `#!/bin/bash
printf '%s\\n' "$*" >> "$TEST_ROOT/sudo-calls"
case "$2" in true|chown) ;; chmod) touch "$TEST_ROOT/repaired" ;; *) exit 99 ;; esac
`, {mode: 0o755});
  const run = () => spawnSync('bash', [path.resolve(__dirname, '../../build/cleanup-taps.sh')], {
    encoding: 'utf8', env: {...process.env, PATH: `${bin}:${process.env.PATH}`,
      TEST_ROOT: root, TEST_REPOSITORY: repository, RUNNER_TEMP: root,
      GITHUB_ACTIONS: String(ci)},
  });
  return {root, tap, run};
}

test('CI repairs only the failed unused tap and retries without touching required taps', t => {
  const f = fixture(t), result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(path.join(f.root, 'calls'), 'utf8'),
    'untap --force example/unused\nuntap --force example/unused\n');
  const privileged = fs.readFileSync(path.join(f.root, 'sudo-calls'), 'utf8').trim().split('\n');
  assert.equal(privileged.length, 3);
  assert.equal(privileged[0], '-n true');
  assert.ok(privileged[1].startsWith('-n chown -R -P '));
  assert.ok(privileged[1].endsWith(` ${f.tap}`));
  assert.equal(privileged[2], `-n chmod -R u+rwX ${f.tap}`);
});

test('tap cleanup does not attempt privileged repair outside CI', t => {
  const f = fixture(t, false), result = f.run();
  assert.equal(result.status, 1);
  assert.match(result.stderr, /permission denied/);
  assert.equal(fs.existsSync(path.join(f.root, 'sudo-calls')), false);
});

test('tap cleanup refuses permission repair through a symlink', t => {
  const f = fixture(t);
  fs.rmdirSync(f.tap);
  fs.symlinkSync(f.root, f.tap);
  assert.equal(f.run().status, 1);
  assert.equal(fs.existsSync(path.join(f.root, 'sudo-calls')), false);
});
