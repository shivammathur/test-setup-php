const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'workflow-preparation-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const bin = path.join(root, 'bin'); fs.mkdirSync(bin);
  return {root, bin, env: {...process.env, PATH: `${bin}:${process.env.PATH}`, RUNNER_TEMP: root}};
}
test('doctor reports config once, tolerates ordinary warnings and rejects broken cleanup', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.bin, 'brew'), `#!/bin/sh
if [ "$1" = config ]; then echo 'fixture config'; exit 0; fi
printf '%s\\n' "$DOCTOR_OUTPUT"
exit "$DOCTOR_STATUS"
`, {mode: 0o755});
  for (const [output, status, expected] of [['Ready', '0', 0], ['Warning: unlinked keg', '1', 0], ['Error: broken prefix', '1', 1]]) {
    const result = spawnSync('bash', ['scripts/build/check-homebrew.sh'], {env: {...f.env, DOCTOR_OUTPUT: output, DOCTOR_STATUS: status}, encoding: 'utf8'});
    assert.equal(result.status, expected, result.stderr);
    assert.match(result.stdout, /fixture config/);
    assert.ok(result.stdout.includes(output));
  }
});
test('extension test preparation never fetches build formulae or requires an extension commit', t => {
  const f = fixture(t), prefix = path.join(f.root, 'prefix'), log = path.join(f.root, 'calls');
  const phpBin = path.join(prefix, 'opt/php@8.4/bin'); fs.mkdirSync(phpBin, {recursive: true});
  fs.writeFileSync(path.join(phpBin, 'php-config'), '#!/bin/sh\necho 8.4.26\n', {mode: 0o755});
  fs.writeFileSync(path.join(f.bin, 'brew'), `#!/bin/sh
printf 'brew %s\\n' "$*" >> "$CALL_LOG"
case "$1" in --prefix|--repository) echo "$FIXTURE_PREFIX";; untap) test "$2" = shivammathur/php;; *) exit 93;; esac
`, {mode: 0o755});
  fs.writeFileSync(path.join(f.bin, 'git'), '#!/bin/sh\necho unexpected-git >> "$CALL_LOG"\nexit 94\n', {mode: 0o755});
  fs.writeFileSync(path.join(f.bin, 'bash'), `#!/bin/sh
case "$1" in */../install.sh) echo existing-archive-installed >> "$CALL_LOG";; *) exit 95;; esac
`, {mode: 0o755});
  const env = {...f.env, PHP_VERSION: '8.4', BUILD: 'release', TS: 'nts', GITHUB_ACTIONS: 'true',
    CALL_LOG: log, FIXTURE_PREFIX: prefix};
  delete env.HOMEBREW_EXTENSIONS_COMMIT;
  const result = spawnSync('/bin/bash', ['scripts/build/prepare-extension-pack.sh', 'test'], {env, encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr + fs.readFileSync(log, 'utf8'));
  const calls = fs.readFileSync(log, 'utf8');
  assert.match(calls, /existing-archive-installed/);
  assert.doesNotMatch(calls, /git|tap shivammathur\/extensions|trust/);
});
