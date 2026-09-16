const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {execFileSync} = require('node:child_process');
const phase = process.argv[2];
const dir = process.env.CACHE_DIR;
const cacheFile = path.join(dir, 'redis-6.2.0');
const activeFile = path.join(dir, 'redis.so');
const marker = path.join(dir, 'versioned-cache-roundtrip.json');
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
fs.mkdirSync('evidence', {recursive: true});
let data;
if (phase === 'seed') {
  const version = execFileSync('php', ['-r', 'echo phpversion("redis");'], {encoding: 'utf8'}).trim();
  if (version !== '6.2.0') throw new Error(`Wrong initial Redis: ${version}`);
  if (hash(cacheFile) !== hash(activeFile)) throw new Error('Versioned binary was not cached');
  data = {run: process.env.GITHUB_RUN_ID, version, sha256: hash(cacheFile), dir, key: process.env.CACHE_KEY, source: process.env.ACTION_SHA};
  fs.writeFileSync(marker, JSON.stringify(data, null, 2));
} else {
  data = JSON.parse(fs.readFileSync(marker, 'utf8'));
  if (data.run !== process.env.GITHUB_RUN_ID || data.key !== process.env.CACHE_KEY || data.source !== process.env.ACTION_SHA) throw new Error('Restored an unexpected cache');
  if (hash(cacheFile) !== data.sha256) throw new Error('Restored versioned binary differs from saved binary');
  if (phase === 'restored') {
    execFileSync('sudo', ['rm', '-f', activeFile, '/tmp/php8.3_extensions']);
    if (fs.existsSync(activeFile)) throw new Error('Failed to remove active extension before cache reuse');
    data.activeRemoved = true;
  } else {
    if (hash(activeFile) !== data.sha256) throw new Error('Enabled binary does not match the restored versioned cache');
    const runtime = JSON.parse(execFileSync('php', ['-r', 'echo json_encode(["version"=>phpversion("redis"), "class"=>get_class(new Redis())]);'], {encoding: 'utf8'}));
    if (runtime.version !== '6.2.0' || runtime.class !== 'Redis') throw new Error(`Redis was not loaded: ${JSON.stringify(runtime)}`);
    data.runtime = runtime;
  }
}
fs.writeFileSync(`evidence/${phase}.json`, JSON.stringify(data, null, 2));
console.log(JSON.stringify(data, null, 2));
