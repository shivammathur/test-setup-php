const { test } = require('node:test');
const assert = require('node:assert/strict');
const { recover } = require('../../build/recover-runner.cjs');

const worker = { pid: 100, ppid: 90, uid: 501, started: 2000, state: 'S', executable: '/runner/bin/Runner.Worker' };
const action = { pid: 101, ppid: 100, uid: 501, started: 3000, state: 'S', executable: '/runner/node' };
const abandoned = { pid: 80, ppid: 1, uid: 501, started: 1000, state: 'S',
  executable: '/usr/local/Homebrew/Library/Homebrew/vendor/portable-ruby/3.4.5/bin/ruby' };

function fixture(extra = {}) {
  const rows = [worker, action, abandoned].map(row => ({ ...row })), signals = [], messages = [];
  const options = { platform: 'darwin', env: { GITHUB_ACTIONS: 'true', RUNNER_ENVIRONMENT: 'self-hosted' },
    prefix: '/usr/local', repository: '/usr/local/Homebrew', uid: 501, pid: 101,
    snapshot: () => rows.map(row => ({ ...row })), isInstaller: () => true, locked: () => true,
    signal: (pid, signal) => { signals.push([pid, signal]); rows.splice(rows.findIndex(row => row.pid === pid), 1); },
    wait: async () => {}, log: text => messages.push(text), warn: text => messages.push(text), ...extra };
  return { options, rows, signals, messages };
}

test('releases an old orphan and its descendants, with no wait on a healthy runner', async () => {
  const f = fixture();
  f.rows.push({ ...abandoned, pid: 81, ppid: 80, executable: '/usr/bin/clang' });
  assert.equal(await recover(f.options), 1);
  assert.deepEqual(f.signals, [[81, 'SIGTERM'], [80, 'SIGTERM']]);
  f.options.wait = () => assert.fail('healthy preflight must not wait');
  assert.equal(await recover(f.options), 0);
});

for (const [label, change] of Object.entries({
  'live parent': row => { row.ppid = 90; },
  'another user': row => { row.uid = 502; },
  'current job': row => { row.started = 3000; },
  'ambiguous start time': row => { row.started = 2000; },
  'service': row => { row.executable = '/usr/local/opt/mysql/bin/mysqld'; },
  'other Homebrew prefix': row => { row.executable = '/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby'; },
  'zombie': row => { row.state = 'Z'; }
})) test(`does not touch ${label}`, async () => {
  const f = fixture();
  change(f.rows[2]);
  assert.equal(await recover(f.options), 0);
  assert.deepEqual(f.signals, []);
});

test('requires one identifiable active worker, an installer command, and a held lock', async () => {
  for (const scenario of ['other-worker', 'no-worker', 'not-installer', 'no-lock']) {
    const f = fixture();
    if (scenario === 'other-worker') f.rows.push({ ...worker, pid: 110, uid: 502 });
    if (scenario === 'no-worker') f.rows.shift();
    if (scenario === 'not-installer') f.options.isInstaller = () => false;
    if (scenario === 'no-lock') f.options.locked = () => false;
    assert.equal(await recover(f.options), 0, scenario);
    assert.deepEqual(f.signals, [], scenario);
  }
});

test('never inspects or kills outside self-hosted macOS Actions jobs', async () => {
  for (const change of [{ platform: 'linux' }, { env: {} },
    { env: { GITHUB_ACTIONS: 'true', RUNNER_ENVIRONMENT: 'github-hosted' } }]) {
    const f = fixture({ ...change, snapshot: () => assert.fail('must not inspect this host') });
    assert.equal(await recover(f.options), 0);
  }
});

test('never signals an ancestor of the current job', async () => {
  const f = fixture();
  f.rows[0].ppid = abandoned.pid;
  assert.equal(await recover(f.options), 0);
  assert.deepEqual(f.signals, []);
});

test('a new worker appearing during TERM prevents further signals', async () => {
  const f = fixture();
  f.options.signal = (pid, sig) => {
    f.signals.push([pid, sig]);
    f.rows.push({ ...worker, pid: 110 });
  };
  assert.equal(await recover(f.options), 0);
  assert.deepEqual(f.signals, [[80, 'SIGTERM']]);
  assert.ok(f.messages.some(message => message.includes('not confirmed')));
});

test('rechecks identity and active workers after lock inspection', async () => {
  for (const scenario of ['pid-reused', 'worker-started', 'reparented']) {
    const f = fixture();
    f.options.locked = () => {
      if (scenario === 'pid-reused') f.rows[2].started++;
      if (scenario === 'worker-started') f.rows.push({ ...worker, pid: 110 });
      if (scenario === 'reparented') f.rows[2].ppid = 90;
      return true;
    };
    assert.equal(await recover(f.options), 0, scenario);
    assert.deepEqual(f.signals, [], scenario);
  }
});

test('bounds TERM grace and does not signal reused PIDs during escalation', async () => {
  const f = fixture();
  let waits = 0;
  f.options.signal = (pid, signal) => f.signals.push([pid, signal]);
  f.options.wait = async () => { if (++waits === 6) f.rows[2].started++; };
  assert.equal(await recover(f.options), 1);
  assert.deepEqual(f.signals, [[80, 'SIGTERM']]);
  assert.ok(waits <= 7);
});

test('inspection failures do not add a job failure or expose command diagnostics', async () => {
  for (const operation of ['snapshot', 'isInstaller', 'locked']) {
    const f = fixture({ [operation]: () => { throw new Error('secret-in-command'); } });
    assert.equal(await recover(f.options), 0);
    assert.deepEqual(f.signals, []);
    assert.ok(!f.messages.join('\n').includes('secret-in-command'));
  }
});
