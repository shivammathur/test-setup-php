const { spawn, execFileSync } = require('node:child_process');

// Homebrew filters RUNNER_TRACKING_ID out of its environment. Keep an
// asynchronous parent that can reap its build tree when Actions cancels the
// step, even while the source-cache worker is blocked in spawnSync.
function supervise(program, args) {
  const child = spawn(program, args, { stdio: 'inherit' });
  const tracked = new Set();
  let stopping = false;
  let closed = false;

  function collect() {
    if (closed || !child.pid) return;
    tracked.add(child.pid);
    const rows = execFileSync('ps', ['-axo', 'pid=,ppid='], { encoding: 'utf8' })
      .trim().split('\n').map(row => row.trim().split(/\s+/).map(Number));
    const descendants = new Set([child.pid]);
    let count;
    do {
      count = descendants.size;
      for (const [pid, parent] of rows) if (descendants.has(parent)) descendants.add(pid);
    } while (count !== descendants.size);
    for (const pid of descendants) tracked.add(pid);
  }

  function signalTree(signal) {
    try { collect(); } catch (error) { console.error(`Could not inspect build children: ${error.message}`); }
    // Include children that created their own process groups, as brew does.
    for (const pid of [...tracked].reverse()) {
      try { process.kill(pid, signal); } catch (error) {
        if (error.code !== 'ESRCH') console.error(`Could not stop build process ${pid}: ${error.message}`);
      }
    }
  }

  function stop(signal) {
    if (stopping) return;
    stopping = true;
    process.exitCode = signal === 'SIGINT' ? 130 : 143;
    signalTree('SIGTERM');
    // Remain alive after the worker exits so uncooperative grandchildren are
    // still reaped before the runner starts its next job. This affects only
    // cancellation, never the installer or successful build path.
    setTimeout(() => signalTree('SIGKILL'), 1500);
  }
  process.on('SIGINT', () => stop('SIGINT'));
  process.on('SIGTERM', () => stop('SIGTERM'));
  child.on('error', error => { console.error(error); process.exitCode = 1; });
  child.on('close', (code, signal) => {
    closed = true;
    if (!stopping) process.exitCode = code ?? (signal === 'SIGINT' ? 130 : signal ? 143 : 1);
  });
}

module.exports = { supervise };
