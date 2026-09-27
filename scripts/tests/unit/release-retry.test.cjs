const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname, '../../..');
function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'release-retry-'));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  return directory;
}
test('shell transfer retries any exit code three times and discards failed stdout', t => {
  for (const code of [1, 22, 35, 60, 77]) for (const recover of [false, true]) {
    const directory = fixture(t);
    const result = spawnSync('bash', ['-c', `
      . scripts/lib/retry.sh
      sleep() { printf '%s\\n' "$1" >> "$STATE/waits"; }
      transfer() {
        local count=0
        [ ! -f "$STATE/count" ] || read -r count < "$STATE/count"
        count=$((count + 1)); printf '%s\\n' "$count" > "$STATE/count"
        if [ "$RECOVER" = true ] && [ "$count" = 3 ]; then printf 'verified'; return 0; fi
        printf 'partial JSON'; return "$FAIL_CODE"
      }
      php_darwin_retry transfer
    `], {cwd: root, encoding: 'utf8', env: {...process.env, STATE: directory, FAIL_CODE: String(code), RECOVER: String(recover)}});
    assert.equal(result.status, recover ? 0 : code, result.stderr);
    assert.equal(result.stdout, recover ? 'verified\n' : '');
    assert.equal(fs.readFileSync(path.join(directory, 'count'), 'utf8'), '3\n');
    assert.equal(fs.readFileSync(path.join(directory, 'waits'), 'utf8'), '1\n2\n');
  }
});
test('immutable upload retry reuses a partially completed batch and bounds permission failures', t => {
  for (const mode of ['partial', 'lost', 'forbidden']) {
    const directory = fixture(t);
    fs.writeFileSync(path.join(directory, 'first'), 'first verified archive');
    fs.writeFileSync(path.join(directory, 'second'), 'second verified archive');
    fs.writeFileSync(path.join(directory, 'gh'), `#!${process.execPath}
      const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
      const args = process.argv.slice(2), stateFile = path.join(process.env.STATE, 'state.json');
      const state = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile)) : {calls: [], assets: []};
      if (args[1] === 'view') { console.log(JSON.stringify({assets: state.assets})); process.exit(0); }
      if (args.includes('--clobber')) throw new Error('must never clobber immutable assets');
      const files = args.slice(3, args.indexOf('--repo'));
      state.calls.push(files.map(file => path.basename(file)));
      if (process.env.MODE !== 'forbidden') for (const file of files) {
        if (state.calls.length === 1 && process.env.MODE === 'partial' && path.basename(file) === 'second') continue;
        state.assets.push({name: path.basename(file), state: 'uploaded', digest: 'sha256:' + crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')});
      }
      fs.writeFileSync(stateFile, JSON.stringify(state));
      process.exit(state.calls.length === 1 || process.env.MODE === 'forbidden' ? 1 : 0);
    `, {mode: 0o755});
    const result = spawnSync('bash', ['-c', `
      . scripts/lib/lib.sh
      . scripts/lib/retry.sh
      sleep() { :; }
      php_darwin_upload_immutable php-8.5 shivammathur/php-darwin "$STATE/first" "$STATE/second"
    `], {cwd: root, encoding: 'utf8', env: {...process.env, PATH: `${directory}:${process.env.PATH}`, STATE: directory, MODE: mode}});
    assert.equal(result.status, mode === 'forbidden' ? 1 : 0, result.stderr);
    const {calls} = JSON.parse(fs.readFileSync(path.join(directory, 'state.json')));
    assert.deepEqual(calls, mode === 'lost' ? [['first', 'second']] : mode === 'partial' ? [['first', 'second'], ['second']] : Array(3).fill(['first', 'second']));
  }
});
