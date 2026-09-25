// Experiment-only process and filesystem timings; no arguments, URLs or secrets.
if (process.env.PHP_DARWIN_PROFILE_LOG && /\/install-extensions\.cjs$/.test(process.argv[1] || '')) {
  const fs = require('node:fs');
  const path = require('node:path');
  const child = require('node:child_process');
  const append = fs.appendFileSync;
  const started = performance.now();
  const operations = {};
  const mode = ['prefetch', 'install'].includes(process.argv[2]) ? process.argv[2] : 'other';
  const pack = ['imagick', 'mongodb', 'memcached'].includes(process.argv[4]) ? process.argv[4] : 'all';
  const log = record => append(process.env.PHP_DARWIN_PROFILE_LOG,
    JSON.stringify({pid: process.pid, mode, pack, ...record}) + '\n');
  const spawn = child.spawnSync;
  child.spawnSync = function (program, args, options) {
    const before = performance.now();
    try { return spawn.call(this, program, args, options); }
    finally {
      const tool = path.basename(program);
      const operation = tool === 'tar' ? (args.includes('-tf') ? 'list' : 'extract') :
        tool === 'php-config' ? (args.includes('--include-dir') ? 'headers' : 'extension-dir') :
        tool === 'php' ? (args.includes('-d') ? 'load' : 'context') : 'query';
      log({tool, operation, seconds: (performance.now() - before) / 1000});
    }
  };
  for (const name of ['readFileSync', 'writeFileSync', 'readdirSync', 'lstatSync', 'statSync',
    'readlinkSync', 'realpathSync', 'mkdirSync', 'chmodSync', 'renameSync', 'symlinkSync', 'rmSync']) {
    const original = fs[name];
    const wrapper = function (...args) {
      const before = performance.now();
      try { return original.apply(this, args); }
      finally {
        const item = operations[name] ||= {count: 0, seconds: 0};
        item.count++;
        item.seconds += (performance.now() - before) / 1000;
      }
    };
    Object.assign(wrapper, original);
    fs[name] = wrapper;
  }
  process.on('exit', () => log({total_seconds: (performance.now() - started) / 1000,
    cpu: process.cpuUsage(), operations}));
}
