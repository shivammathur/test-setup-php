// Populate Homebrew's own download cache; installation, relocation and receipts
// remain Homebrew's responsibility. Never select a bottle by version alone.
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { recordMetric } = require('../lib/build-metrics.cjs');
const { retryPolicy, httpError } = require('../release/extension-transfers.cjs');
const DOMAIN = 'https://artifacts.php-darwin.setup-php.com';

function validate(record) {
  if (!record || !/^(?:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/)?[A-Za-z0-9@+_.-]+$/.test(record.formula) ||
      !/^[0-9a-f]{64}$/.test(record.sha256) || !/^[A-Za-z0-9_.+-]+$/.test(record.version) ||
      !/^[A-Za-z0-9_]+$/.test(record.tag)) throw new Error('Invalid upstream bottle identity');
  const url = new URL(record.url);
  if (url.origin !== 'https://ghcr.io' || url.search || url.hash || url.username || url.password ||
      !/^\/v2\/(?:homebrew\/core|shivammathur\/(?:php|extensions))\/[a-z0-9+_.\/-]+\/blobs\/sha256:[a-f0-9]{64}$/.test(url.pathname) ||
      !url.pathname.endsWith(`sha256:${record.sha256}`) || url.pathname.includes('/../')) {
    throw new Error(`Unsupported upstream bottle URL: ${record.url}`);
  }
  return record;
}
function portable(record) {
  validate(record);
  const { formula, version, tag, sha256, url } = record;
  return { formula, version, tag, sha256, url };
}
function key(record) { return `homebrew/bottles/sha256/${validate(record).sha256}.tar.gz`; }
function publicURL(record) { return `${DOMAIN}/${key(record)}`; }
async function sha256(file) {
  const hash = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}
async function validFile(file, expected) {
  try { return (await fsp.lstat(file)).isFile() && await sha256(file) === expected; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
function exec(program, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { stdio: ['ignore', 'pipe', 'inherit'], ...options });
    let output = '';
    child.stdout?.on('data', data => { output += data; });
    child.on('error', reject);
    child.on('close', code => {
      if (code === 0) return resolve(output.trim());
      const error = new Error(`${program} exited ${code}`);
      error.transient = true;
      Object.defineProperty(error, 'output', { value: output.trim() });
      reject(error);
    });
  });
}
async function transfer(url, file, { head = false, upstream = false } = {}) {
  // One attempt here: publication wraps failures in its shared retry
  // budget, while build prefetch can promptly fall back to normal Homebrew.
  const args = ['-q', '--fail', '--silent', '--show-error', '--location', '--proto', '=https',
    '--proto-redir', '=https', '--connect-timeout', '5', '--max-time', head ? '10' : '180',
    '--output', file, '--write-out', '%{http_code}'];
  if (head) args.push('--head');
  if (upstream) args.push('--header', 'Authorization: Bearer QQ==');
  args.push(url);
  try { return Number(await exec('curl', args)); }
  catch (error) {
    if (/^[45]\d{2}$/.test(error.output || '')) return Number(error.output);
    throw Object.assign(new Error(`Download failed: ${url}: ${error.message}`, { cause: error }),
      { transient: Boolean(error.transient) });
  }
}
async function pool(items, concurrency, work) {
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (next < items.length) await work(items[next++]);
  }));
}
async function prefetch(records, { download = transfer, log = console.log, warn = console.warn,
  missFile = process.env.PHP_DARWIN_BOTTLE_MISSES, retry = retryPolicy() } = {}) {
  await pool(records, 8, async record => {
    validate(record);
    if (!path.isAbsolute(record.cached_download || '')) throw new Error('Missing Homebrew download path');
    const started = Date.now();
    let result = 'miss';
    let temporary;
    try {
      if (await validFile(record.cached_download, record.sha256)) {
        result = 'local';
        // Still enqueue a new upstream revision that another job fetched locally.
        const status = await retry('Cloudflare bottle lookup', async () => {
          const response = await download(publicURL(record), os.devNull, { head: true });
          if (response !== 200 && response !== 404) throw httpError(response, 'Cloudflare bottle lookup');
          return response;
        });
        if (status !== 200) result = 'local-miss';
      } else {
        await fsp.mkdir(path.dirname(record.cached_download), { recursive: true });
        temporary = `${record.cached_download}.r2-${process.pid}-${crypto.randomUUID()}`;
        const status = await retry('Cloudflare bottle download', async () => {
          const response = await download(publicURL(record), temporary);
          if (response !== 200 && response !== 404) throw httpError(response, 'Cloudflare bottle download');
          if (response === 200 && !await validFile(temporary, record.sha256)) throw new Error('Cloudflare bottle checksum mismatch');
          return response;
        });
        if (status === 200) {
          await fsp.rename(temporary, record.cached_download);
          result = 'hit';
        } else if (status !== 404) throw new Error(`Cloudflare returned HTTP ${status}`);
      }
    } catch (error) {
      warn(`${record.formula}: ${error.message}; using Homebrew upstream fallback`);
    } finally {
      if (temporary) await fsp.rm(temporary, { force: true });
    }
    if (result === 'miss' || result === 'local-miss') {
      if (missFile) fs.appendFileSync(missFile, JSON.stringify(portable(record)) + '\n');
      log(`Cloudflare bottle MISS: ${record.formula} ${record.version} ${record.tag}; queued for caching`);
    } else log(`Cloudflare bottle ${result.toUpperCase()}: ${record.formula} ${record.version} ${record.tag}`);
    recordMetric({ kind: 'bottle-cache', formula: record.formula, result, elapsedMs: Date.now() - started });
  });
}
function matrix(records) {
  const groups = new Map();
  for (const item of records) {
    const record = portable(item);
    if (!groups.has(record.formula)) groups.set(record.formula, new Map());
    groups.get(record.formula).set(record.sha256, record);
  }
  if (groups.size > 256) throw new Error('Bottle dependency matrix exceeds 256 jobs');
  return { include: [...groups].sort(([a], [b]) => a.localeCompare(b)).map(([formula, bottles]) => ({
    formula, bottles: [...bottles.values()],
  })) };
}
function readRecords(directory) {
  const records = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) records.push(...readRecords(file));
    else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
      for (const line of fs.readFileSync(file, 'utf8').split('\n').filter(Boolean)) records.push(JSON.parse(line));
    }
  }
  return records;
}
async function publish(records, { download = transfer, run = exec, env = process.env,
  identity = portable, objectKey = key, contentType = 'application/gzip', upstream = true,
  retry = retryPolicy({ attempts: 3, budget: 12, delay: 1000 }) } = {}) {
  const endpoint = env.CF_R2_AWS_S3_ENDPOINT;
  if (!/^https:\/\/[a-f0-9]+\.r2\.cloudflarestorage\.com\/?$/.test(endpoint || '') ||
      !env.CF_R2_AWS_ACCESS_KEY_ID || !env.CF_R2_AWS_SECRET_ACCESS_KEY) throw new Error('Missing R2 configuration');
  const directory = await fsp.mkdtemp(path.join(os.tmpdir(), 'php-darwin-bottles-'));
  const results = [];
  const readPublic = (url, file) => retry('Cloudflare bottle read', async () => {
    const status = await download(url, file);
    if (status !== 200 && status !== 404) throw httpError(status, 'Cloudflare read failed');
    return status;
  });
  try {
    for (const raw of records) {
      const record = identity(raw);
      const publicUrl = `${DOMAIN}/${objectKey(record)}`;
      console.log(`Checking Cloudflare: ${record.formula} ${record.version} ${record.sha256}`);
      const file = path.join(directory, record.sha256);
      let result = 'existing';
      // Check full bytes on both existing and newly published immutable objects.
      let status = await readPublic(publicUrl, file);
      if (status !== 200 || !await validFile(file, record.sha256)) {
        if (status !== 200 && status !== 404) throw new Error(`Cloudflare read failed: HTTP ${status}`);
        status = await retry('Upstream bottle read', async () => {
          const response = await download(record.url, file, { upstream });
          if (response !== 200) throw httpError(response, 'Upstream bottle read failed');
          if (!await validFile(file, record.sha256)) throw new Error(`Invalid upstream bottle: ${record.formula}`);
          return response;
        });
        if (status !== 200 || !await validFile(file, record.sha256)) throw new Error(`Invalid upstream bottle: ${record.formula}`);
        const awsOptions = { env: {
          ...env, AWS_ACCESS_KEY_ID: env.CF_R2_AWS_ACCESS_KEY_ID,
          AWS_SECRET_ACCESS_KEY: env.CF_R2_AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION: 'auto',
          AWS_EC2_METADATA_DISABLED: 'true', AWS_MAX_ATTEMPTS: '1', AWS_RETRY_MODE: 'standard',
          AWS_REQUEST_CHECKSUM_CALCULATION: 'when_required', AWS_RESPONSE_CHECKSUM_VALIDATION: 'when_required',
        } };
        let uploadAttempted = false;
        await retry('R2 bottle upload', async () => {
          if (uploadAttempted) {
            // A lost upload reply may still have committed the object. Reconcile
            // public bytes before sending the same content-addressed file again.
            const existing = `${file}.existing`;
            const response = await download(`${publicUrl}?verify=${crypto.randomUUID()}`, existing);
            if (response === 200 && await validFile(existing, record.sha256)) return;
            if (response !== 200 && response !== 404) throw httpError(response, 'R2 upload reconciliation');
          }
          uploadAttempted = true;
          await run('aws', ['--endpoint-url', endpoint, 's3', 'cp', file, `s3://php-darwin/${objectKey(record)}`,
          '--cache-control', 'public,max-age=31536000,immutable', '--content-type', contentType,
          '--cli-connect-timeout', '5', '--cli-read-timeout', '60', '--only-show-errors'], awsOptions);
        });
        // Bypass negative edge caches and retry verification without repeating
        // an upload. Every successful read must also match the expected digest.
        try {
          await retry('Verify published bottle', async () => {
            status = await download(`${publicUrl}?verify=${crypto.randomUUID()}`, file);
            if (status !== 200 || !await validFile(file, record.sha256)) {
              throw new Error(`Published bottle verification failed: ${record.formula} HTTP ${status}, expected ${record.sha256}`);
            }
          });
        } catch (error) {
          if (status === 404) {
            const remote = await retry('Inspect R2 bottle', async () => JSON.parse(await run('aws', ['--endpoint-url', endpoint, 's3api', 'head-object',
              '--bucket', 'php-darwin', '--key', objectKey(record),
              '--cli-connect-timeout', '5', '--cli-read-timeout', '30'], awsOptions)));
            console.error(`R2 object exists behind public 404: ${objectKey(record)}; ` +
              `${remote.ContentLength} bytes, ETag ${remote.ETag}`);
          }
          throw error;
        }
        result = 'uploaded';
      }
      console.log(`Verified ${record.formula} ${record.version} ${record.tag}: ${result} ${record.sha256}`);
      results.push({ ...record, result });
      await fsp.rm(file, { force: true });
    }
    return results;
  } finally { await fsp.rm(directory, { recursive: true, force: true }); }
}
async function main() {
  if (process.argv[2] === 'matrix') {
    const result = matrix(readRecords(process.argv[3]));
    fs.writeFileSync('bottle-matrix.json', JSON.stringify(result, null, 2));
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `matrix=${JSON.stringify(result)}\ncount=${result.include.length}\n`);
    console.log(`${result.include.length} dependency jobs`);
  } else if (process.argv[2] === 'publish') {
    const result = await publish(JSON.parse(process.env.BOTTLES));
    fs.writeFileSync('bottle-verification.json', JSON.stringify(result, null, 2));
  } else if (process.argv[2] === 'tools') {
    const { command } = require('./source-bottle-cache.cjs');
    const plan = JSON.parse(command('brew', ['php-darwin-source', 'info', 'plan', '["jq","zstd"]', 'false'], {
      env: { PATH: `${__dirname}${path.delimiter}${process.env.PATH}` },
    }));
    await prefetch(plan.filter(item => !item.installed && item.bottle).map(item => item.bottle));
  } else throw new Error('Expected matrix, publish, or tools');
}
module.exports = { validate, portable, key, publicURL, sha256, validFile, exec, transfer, pool, prefetch, matrix, readRecords, publish };
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });
