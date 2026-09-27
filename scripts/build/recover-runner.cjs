const { execFileSync } = require('node:child_process');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');

function command(program, args) {
  return execFileSync(program, args, { encoding: 'utf8', timeout: 5000,
    env: { ...process.env, LC_ALL: 'C', TZ: 'UTC' }, stdio: ['ignore', 'pipe', 'pipe'] });
}

function processes() {
  return command('/bin/ps', ['-ww', '-axo', 'pid=,ppid=,uid=,lstart=,stat=,comm=']).trim().split('\n').flatMap(line => {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+\s+\d+)\s+(\S+)\s+(.+)$/);
    if (!match) return [];
    const [, pid, ppid, uid, start, state, executable] = match;
    return [{ pid: Number(pid), ppid: Number(ppid), uid: Number(uid), started: Date.parse(`${start} UTC`), state, executable }];
  });
}

function sameProcess(a, b) {
  return a && b && a.pid === b.pid && a.uid === b.uid && a.started === b.started &&
    a.executable === b.executable && !b.state.startsWith('Z');
}

function currentWorker(rows, pid) {
  const workers = rows.filter(row => path.basename(row.executable) === 'Runner.Worker' && !row.state.startsWith('Z'));
  // A prefix shared by concurrent jobs is not safe to repair automatically.
  if (workers.length !== 1) return undefined;
  const seen = new Set();
  while (pid > 1 && !seen.has(pid)) {
    if (pid === workers[0].pid) return workers[0];
    seen.add(pid);
    pid = rows.find(row => row.pid === pid)?.ppid;
  }
}

function orphan(row, worker, uid, repository) {
  const ruby = path.join(repository, 'Library/Homebrew/vendor/portable-ruby/');
  return row.ppid === 1 && row.uid === uid && row.started < worker.started && !row.state.startsWith('Z') &&
    row.executable.startsWith(ruby) && /^[\w.+-]+\/bin\/ruby$/.test(row.executable.slice(ruby.length));
}

function installer(pid, repository) {
  const args = command('/bin/ps', ['-ww', '-p', String(pid), '-o', 'args=']).trim().split(/\s+/);
  const index = args.indexOf(path.join(repository, 'Library/Homebrew/brew.rb'));
  return index > 0 && ['install', 'reinstall', 'upgrade'].includes(args[index + 1]);
}

function holdsLocks(pid, prefix) {
  const directory = path.join(prefix, 'var/homebrew/locks');
  const output = command('/usr/sbin/lsof', ['-nP', '-a', '-p', String(pid), '-F', 'pn']);
  const files = output.split('\n').filter(line => line.startsWith('n')).map(line => line.slice(1))
    .filter(file => path.dirname(file) === directory && /^[\w@.+-]+\.lock$/.test(path.basename(file)));
  for (const file of [...new Set(files)]) {
    // lsof on macOS does not report flock ownership. Require this process to
    // be the only opener, then prove the existing inode is exclusively locked.
    const holders = command('/usr/sbin/lsof', ['-nP', '-t', file]).trim().split(/\s+/);
    if (holders.length !== 1 || holders[0] !== String(pid)) continue;
    const held = command('/usr/bin/ruby', ['-e',
      'File.open(ARGV.fetch(0), "r+") { |f| puts(f.flock(File::LOCK_EX | File::LOCK_NB) ? "free" : "held") }', file]);
    if (held.trim() === 'held') return true;
  }
  return false;
}

function descendants(root, rows) {
  const tree = [root], seen = new Set([root.pid]);
  for (let index = 0; index < tree.length; index++) {
    for (const row of rows) if (row.ppid === tree[index].pid && row.uid === root.uid && !seen.has(row.pid)) {
      tree.push(row);
      seen.add(row.pid);
    }
  }
  return tree.reverse();
}

async function recover({ env = process.env, platform = process.platform, pid = process.pid, uid = process.getuid?.(),
  prefix = process.arch === 'arm64' ? '/opt/homebrew' : '/usr/local',
  repository = prefix === '/usr/local' ? '/usr/local/Homebrew' : prefix,
  snapshot = processes, isInstaller = installer, locked = holdsLocks, signal = process.kill,
  wait = delay, log = console.log, warn = console.warn } = {}) {
  if (platform !== 'darwin' || env.GITHUB_ACTIONS !== 'true' || env.RUNNER_ENVIRONMENT !== 'self-hosted') return 0;
  let recovered = 0;
  try {
    const initial = snapshot(), worker = currentWorker(initial, pid);
    if (!worker || worker.uid !== uid) {
      log('Runner preflight: skipping recovery because an exclusive current job cannot be identified.');
      return 0;
    }
    for (const candidate of initial.filter(row => orphan(row, worker, uid, repository))) {
      try {
        if (!isInstaller(candidate.pid, repository) || !locked(candidate.pid, prefix)) continue;
        const rows = snapshot(), owner = rows.find(row => row.pid === candidate.pid);
        if (!sameProcess(worker, currentWorker(rows, pid)) || !sameProcess(candidate, owner) ||
            !orphan(owner, worker, uid, repository)) continue;
        const tree = descendants(owner, rows);
        if (tree.some(member => member.pid === worker.pid || member.pid === pid)) continue;
        const stop = sig => {
          for (const member of tree) {
            const fresh = snapshot();
            if (!sameProcess(worker, currentWorker(fresh, pid))) return;
            if (!sameProcess(member, fresh.find(row => row.pid === member.pid))) continue;
            try { signal(member.pid, sig); } catch (error) { if (error.code !== 'ESRCH') throw error; }
          }
        };
        log(`Runner preflight: stopping abandoned Homebrew installer ${owner.pid} and ${tree.length - 1} descendants.`);
        stop('SIGTERM');
        let live;
        for (let attempt = 0; attempt < 6; attempt++) {
          const fresh = snapshot();
          live = tree.some(member => sameProcess(member, fresh.find(row => row.pid === member.pid)));
          if (!live) break;
          await wait(250);
        }
        if (live) {
          stop('SIGKILL');
          await wait(250);
        }
        const final = snapshot();
        if (tree.some(member => sameProcess(member, final.find(row => row.pid === member.pid)))) {
          warn(`Runner preflight: candidate ${candidate.pid} still has live processes; recovery was not confirmed.`);
          continue;
        }
        recovered++;
      } catch {
        // A disappearing process or unavailable inspection tool is not a new
        // build failure. Never print argv/environment, which may contain secrets.
        warn(`Runner preflight: could not safely recover candidate ${candidate.pid}; leaving further cleanup to the runner operator.`);
      }
    }
    log(`Runner preflight: recovered ${recovered} abandoned Homebrew installer(s); lock files and caches retained.`);
  } catch {
    warn('Runner preflight: process inspection unavailable; skipping automatic recovery.');
  }
  return recovered;
}

module.exports = { recover, processes, currentWorker, sameProcess, orphan, installer, holdsLocks };
