const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');
const { recover, processes, installer, holdsLocks } = require('../../build/recover-runner.cjs');

// All executable links, Ruby scripts, locks and cache files are private fixtures.
// This suite never runs brew or inspects/changes a real Homebrew prefix.
async function fixture(t, ignoreTerm, holdLock = true) {
  const directory = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'php-darwin-preflight-')));
  const prefix = path.join(directory, 'prefix'), repository = path.join(prefix, 'Homebrew');
  const ruby = path.join(repository, 'Library/Homebrew/vendor/portable-ruby/current/bin/ruby');
  const script = path.join(repository, 'Library/Homebrew/brew.rb');
  const lock = path.join(prefix, 'var/homebrew/locks/fixture.formula.lock');
  const cache = path.join(prefix, 'cached-bottle.tar.gz'), marker = path.join(directory, 'ready.json');
  const diagnostic = path.join(directory, 'fixture.log');
  const pidFile = path.join(directory, 'fixture.pid');
  const workerPath = path.join(directory, 'Runner.Worker');
  fs.mkdirSync(path.dirname(ruby), { recursive: true });
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  fs.symlinkSync('/usr/bin/ruby', ruby);
  fs.symlinkSync(process.execPath, workerPath);
  fs.writeFileSync(cache, 'successful bottle must survive runner recovery');
  fs.writeFileSync(script, `require 'json'
f = File.open(ARGV.fetch(1), 'w+')
abort 'fixture lock unavailable' if ARGV.fetch(4) == 'true' && !f.flock(File::LOCK_EX | File::LOCK_NB)
ignore = ARGV.fetch(3) == 'true'
trap('TERM') {} if ignore
child = fork { f.close; trap('TERM') {} if ignore; loop { sleep 1 } }
File.write(ARGV.fetch(2), JSON.generate({pid: Process.pid, child: child}))
loop { sleep 1 }
`);
  let worker, record;
  t.after(async () => {
    const ready = record || (fs.existsSync(marker) ? JSON.parse(fs.readFileSync(marker)) : {});
    const root = ready.pid || (fs.existsSync(pidFile) ? Number(fs.readFileSync(pidFile, 'utf8')) : undefined);
    for (const pid of [ready.child, root, worker?.pid]) {
      if (pid) try { process.kill(pid, 'SIGKILL'); } catch {}
    }
    if (worker) await new Promise(resolve => worker.exitCode !== null || worker.signalCode ? resolve() : worker.once('close', resolve));
    fs.rmSync(directory, { recursive: true, force: true });
  });
  // Wait for actual readiness before the launcher exits. A cold macOS Ruby can
  // take longer than two seconds to start; abandoning the launcher sooner also
  // loses useful startup diagnostics and can leave a late fixture untracked.
  execFileSync(process.execPath, ['-e', `
    const fs = require('node:fs'), log = fs.openSync(${JSON.stringify(diagnostic)}, 'w');
    const child = require('node:child_process').spawn(${JSON.stringify(ruby)}, ${JSON.stringify([script, 'install', lock, marker, String(ignoreTerm), String(holdLock)])},
      { detached: true, stdio: ['ignore', log, log], env: { PATH: '/usr/bin:/bin' } });
    fs.writeFileSync(${JSON.stringify(pidFile)}, String(child.pid));
    let ready = false;
    const timeout = setTimeout(() => { child.kill('SIGKILL'); process.exitCode = 1; }, 10000);
    const timer = setInterval(() => {
      try { JSON.parse(fs.readFileSync(${JSON.stringify(marker)})); } catch { return; }
      ready = true; clearTimeout(timeout); clearInterval(timer); child.unref();
    }, 25);
    child.on('exit', () => {
      if (!ready) { clearTimeout(timeout); clearInterval(timer); process.stderr.write(fs.readFileSync(${JSON.stringify(diagnostic)})); process.exitCode = 1; }
    });
  `], { timeout: 12000, stdio: 'pipe' });
  record = JSON.parse(fs.readFileSync(marker));
  assert.equal(processes().find(row => row.pid === record.pid).ppid, 1);
  assert.equal(installer(record.pid, repository), true);
  // ps start times have one-second precision. Make the new job unambiguously newer.
  await delay(1100);
  worker = spawn(workerPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
  assert.ok(worker.pid);
  const snapshot = () => processes().filter(row => path.basename(row.executable) !== 'Runner.Worker' || row.pid === worker.pid);
  const options = { platform: 'darwin', env: { GITHUB_ACTIONS: 'true', RUNNER_ENVIRONMENT: 'self-hosted' },
    pid: worker.pid, prefix, repository, snapshot };
  return { options, prefix, repository, lock, cache, record, snapshot };
}

for (const ignoreTerm of [false, true]) test(`native orphan cleanup ${ignoreTerm ? 'escalates to KILL' : 'releases locks after TERM'}`,
  { skip: process.platform !== 'darwin', timeout: 30000 }, async t => {
    const f = await fixture(t, ignoreTerm), inode = fs.statSync(f.lock).ino;
    assert.equal(holdsLocks(f.record.pid, f.prefix), true);
    const started = Date.now();
    assert.equal(await recover(f.options), 1);
    const elapsed = Date.now() - started;
    assert.ok(elapsed < 5000, `cleanup exceeded bound: ${elapsed}ms`);
    assert.equal(fs.statSync(f.lock).ino, inode, 'never replace a lock inode');
    assert.equal(fs.readFileSync(f.cache, 'utf8'), 'successful bottle must survive runner recovery');
    execFileSync('/usr/bin/ruby', ['-e',
      'File.open(ARGV.fetch(0), "r+") { |f| abort "lock still held" unless f.flock(File::LOCK_EX | File::LOCK_NB) }', f.lock],
    { stdio: 'pipe' });
    for (const pid of [f.record.pid, f.record.child]) {
      const row = f.snapshot().find(item => item.pid === pid);
      assert.ok(!row || row.state.startsWith('Z'), `abandoned process ${pid} survived`);
    }
    const healthy = Date.now();
    assert.equal(await recover({ ...f.options, wait: () => assert.fail('healthy runner must not wait') }), 0);
    console.log(JSON.stringify({ case: ignoreTerm ? 'kill' : 'term', elapsed_ms: elapsed,
      healthy_ms: Date.now() - healthy, lock_inode_preserved: true, lock_available: true, cache_preserved: true }));
  });

test('native ambiguous lock ownership is left alone', { skip: process.platform !== 'darwin', timeout: 30000 }, async t => {
  const f = await fixture(t, false);
  // Merely opening a lock does not prove ownership when there are other openers.
  assert.equal(holdsLocks(f.record.pid, f.prefix), true);
  const opened = spawn('/usr/bin/ruby', ['-e', 'f=File.open(ARGV[0], "r+"); STDOUT.sync=true; puts "ready"; sleep 10', f.lock],
    { stdio: ['ignore', 'pipe', 'ignore'] });
  t.after(() => opened.kill('SIGKILL'));
  await new Promise(resolve => opened.stdout.once('data', resolve));
  // An additional opener makes ownership ambiguous: neither may be killed.
  assert.equal(holdsLocks(f.record.pid, f.prefix), false);
  assert.equal(await recover({ ...f.options, signal: () => assert.fail('ambiguous owner must survive') }), 0);
});

test('native open but unlocked files do not authorize cleanup', { skip: process.platform !== 'darwin', timeout: 30000 }, async t => {
  const f = await fixture(t, false, false);
  assert.equal(holdsLocks(f.record.pid, f.prefix), false);
  assert.equal(await recover({ ...f.options, signal: () => assert.fail('unlocked installer must survive') }), 0);
});
