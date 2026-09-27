const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');
const supervisor = require.resolve('../../build/supervise-build.cjs');

function launch(program, args) {
  return spawn(process.execPath, ['-e',
    `require(${JSON.stringify(supervisor)}).supervise(${JSON.stringify(program)}, ${JSON.stringify(args)})`],
  { stdio: ['ignore', 'pipe', 'pipe'] });
}

test('supervisor preserves output and failing exit status', async () => {
  const child = launch(process.execPath, ['-e', 'console.log("build output"); process.exitCode = 17']);
  let output = '';
  child.stdout.on('data', data => { output += data; });
  const code = await new Promise(resolve => child.on('close', resolve));
  assert.equal(code, 17);
  assert.equal(output, 'build output\n');
});

test('cancellation reaps a detached child without the Actions tracking variable', { timeout: 10000 }, async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'php-darwin-supervisor-'));
  const marker = path.join(directory, 'child.json');
  const worker = path.join(directory, 'worker.cjs');
  const grandchild = `
    process.on('SIGTERM', () => {});
    require('node:fs').writeFileSync(${JSON.stringify(marker)}, JSON.stringify({
      pid: process.pid, tracking: process.env.RUNNER_TRACKING_ID || null
    }));
    setInterval(() => {}, 1000);
  `;
  fs.writeFileSync(worker, `
    process.on('SIGTERM', () => {});
    require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(grandchild)}], {
      detached: true, stdio: 'ignore', env: {}
    });
    setInterval(() => {}, 1000);
  `);
  const child = launch(process.execPath, [worker]);
  const completion = new Promise(resolve => child.on('close', resolve));
  let pid;
  try {
    for (let attempt = 0; !fs.existsSync(marker) && attempt < 100; attempt++) await delay(20);
    const record = JSON.parse(fs.readFileSync(marker));
    pid = record.pid;
    assert.equal(record.tracking, null);
    const started = Date.now();
    child.kill('SIGTERM');
    assert.equal(await completion, 143);
    assert.ok(Date.now() - started < 5000);
    let state = '';
    try { state = execFileSync('ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' }).trim(); }
    catch (error) { assert.equal(error.status, 1); }
    assert.ok(!state || state.startsWith('Z'), `detached build is still running: ${state}`);
  } finally {
    child.kill('SIGKILL');
    if (pid) { try { process.kill(pid, 'SIGKILL'); } catch {} }
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
