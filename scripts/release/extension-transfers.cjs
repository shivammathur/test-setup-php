const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { digest, origins } = require('../installer/install-extensions.cjs');

// Release and recovery only: no added work in the installation fast path.
function command(program, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { ...options, stdio: ['ignore', 'pipe', 'pipe'], timeout: 180000 });
    let output = '', diagnostic = '';
    child.stdout.on('data', chunk => { output += chunk; });
    child.stderr.on('data', chunk => { diagnostic = (diagnostic + chunk).slice(-8192); });
    child.on('error', reject);
    child.on('close', code => {
      if (code === 0) return resolve(output.trim());
      const error = new Error(`${program} exited ${code}: ${diagnostic.trim()}`);
      // Curl still writes transfer metrics when it times out. Keep stdout
      // available to the reader without exposing arbitrary command output in logs.
      Object.defineProperty(error, 'output', { value: output.trim() });
      error.transient = true;
      reject(error);
    });
  });
}
function retryPolicy({ wait = ms => new Promise(resolve => setTimeout(resolve, ms)), budget = 12,
  attempts = 3, delay = 1000 } = {}) {
  return async (label, work) => {
    for (let attempt = 1; ; attempt++) {
      try { return await work(); }
      catch (error) {
        // Bound both an individual operation and all recovery work in the job.
        // Every error gets the same bounded recovery; validation still runs on each attempt.
        if (attempt >= attempts || budget-- <= 0) throw error;
        const pause = Math.min(Math.max(delay * 2 ** (attempt - 1), error.retryAfterMs || 0), 30000);
        console.warn(`${label}: transfer failed; recovery attempt ${attempt + 1}/${attempts} in ${pause / 1000} seconds (${budget} remain for this job)`);
        await wait(pause);
      }
    }
  };
}
function httpError(status, label) {
  const error = new Error(`${label}: HTTP ${status}`);
  error.transient = true;
  return error;
}
function readDiagnostic(output, headerFile, downloaded) {
  const [status = '', timing = ''] = String(output || '').split('\n');
  const values = timing.split(' '), result = { http_status: /^\d{3}$/.test(status) ? Number(status) : 0 };
  ['dns_seconds', 'connect_seconds', 'tls_seconds', 'first_byte_seconds', 'total_seconds', 'received_bytes'].forEach((name, i) => {
    if (/^\d+(?:\.\d+)?$/.test(values[i] || '')) result[name] = Number(values[i]);
  });
  if (/^[\d.]+$/.test(values[6] || '')) result.http_version = values[6];
  if (/^[\da-fA-F:.]+$/.test(values[7] || '')) result.remote_ip = values[7];
  result.saved_bytes = fs.existsSync(downloaded) ? fs.statSync(downloaded).size : 0;
  let headers = {};
  if (fs.existsSync(headerFile)) for (const line of fs.readFileSync(headerFile, 'utf8').split(/\r?\n/)) {
    if (line.startsWith('HTTP/')) headers = {};
    const match = line.match(/^(cf-ray|cf-cache-status|age|content-length|content-range|retry-after):\s*([\w ,./:-]{1,100})$/i);
    if (match) headers[match[1].toLowerCase()] = match[2];
  }
  return { ...result, headers };
}
async function githubJSON(route, { run = command, retry = retryPolicy(), paginate = false } = {}) {
  return retry(`Read ${route}`, async () => JSON.parse(await run('gh',
    ['api', ...(paginate ? ['--paginate', '--slurp'] : []), route])));
}
async function workflowJobs(route, attempts, options = {}) {
  if (!Number.isSafeInteger(attempts) || attempts < 1) throw new Error('Invalid source run attempt');
  const jobs = new Map();
  // The run-wide jobs endpoint can return 502 for large cancelled matrices.
  // Explicit attempts also retain successful jobs omitted from partial reruns.
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const pages = await githubJSON(`${route}/attempts/${attempt}/jobs?per_page=100`, { ...options, paginate: true });
    for (const job of pages.flatMap(page => page.jobs)) jobs.set(job.name, job);
  }
  return [...jobs.values()];
}
function transfers({ directory, env, endpoint, run = command, retry = retryPolicy(),
  cloudflareRetry = retryPolicy({ attempts: 3, budget: 12, delay: 1000 }) }) {
  const repo = 'shivammathur/php-darwin', release = 'extensions';
  let assets;
  const report = { github_reused: 0, github_uploaded: 0, cloudflare_reused: 0, cloudflare_uploaded: 0, reads: [] };
  async function refreshAssets() {
    const record = JSON.parse(await run('gh', ['api', `repos/${repo}/releases/tags/${release}`]));
    assets = new Map(JSON.parse(await run('gh', ['api', '--paginate', '--slurp',
      `repos/${repo}/releases/${record.id}/assets?per_page=100`])).flat().map(asset => [asset.name, asset]));
  }
  async function read(file, base, { missing = false, different = false, fresh = true, resume = false } = {}) {
    const name = path.basename(file), downloaded = path.join(directory, `verify-${name}`);
    const headers = `${downloaded}.headers`;
    const partial = `${downloaded}.partial`, expected = fs.readFileSync(file);
    const prefix = resume && fs.existsSync(partial) ? fs.readFileSync(partial) : Buffer.alloc(0);
    const offset = prefix.length;
    let output = '', failure, verified = false;
    let assembled = 0;
    try {
      let transportError;
      try {
        output = await run('curl', ['-q', '--fail', '--silent', '--show-error', '--location',
          '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', '5', '--max-time', '45',
          ...(offset ? ['--range', `${offset}-`] : []),
          '--output', downloaded, '--dump-header', headers, '--write-out',
          '%{http_code}\n%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{http_version} %{remote_ip}',
          `${base}/${name}${fresh ? `?verify=${Date.now()}` : ''}`]);
      } catch (error) { transportError = error; output = error.output || ''; }
      const status = output.split('\n')[0];
      const received = fs.existsSync(downloaded) ? fs.readFileSync(downloaded) : Buffer.alloc(0);
      let complete = received;
      if (status === '206') {
        const range = readDiagnostic(output, headers, downloaded).headers['content-range'];
        if (!offset || range !== `bytes ${offset}-${expected.length - 1}/${expected.length}`) {
          throw new Error(`Invalid Content-Range: ${name}`);
        }
        complete = Buffer.concat([prefix, received]);
      }
      // A server may ignore Range and return the full object; replace the prefix
      // in that case. Authenticate every retained byte against the local archive.
      if (resume && ['200', '206'].includes(status)) {
        assembled = complete.length;
        if (complete.length > expected.length || !complete.equals(expected.subarray(0, complete.length))) {
          throw new Error(`Checksum/size mismatch: ${name}`);
        }
        if (complete.length === expected.length && digest(complete) === digest(expected)) {
          verified = true; return true;
        }
        if (transportError && complete.length) fs.writeFileSync(partial, complete, { mode: 0o600 });
      }
      if (status === '404' && missing) return false;
      if (/^[45]\d{2}$/.test(status)) {
        const error = httpError(status, `Verify ${name}`);
        const after = readDiagnostic(output, headers, downloaded).headers['retry-after'];
        const delay = /^\d+$/.test(after || '') ? Number(after) * 1000 : Date.parse(after) - Date.now();
        if (Number.isFinite(delay) && delay > 0) error.retryAfterMs = Math.min(delay, 30000);
        throw error;
      }
      if (transportError) throw transportError;
      if (status !== '200' && !(resume && status === '206')) throw httpError(status, `Verify ${name}`);
      if (complete.length !== expected.length || digest(complete) !== digest(expected)) {
        if (different) return false;
        throw new Error(`Checksum/size mismatch: ${name}`);
      }
      verified = true;
      return true;
    } catch (error) {
      failure = error;
      output = error.output || output;
      throw error;
    } finally {
      const diagnostic = { file: name, origin: base === origins[0] ? 'github' : 'cloudflare',
        ...readDiagnostic(output, headers, downloaded), ...(offset ? { resume_offset: offset } : {}),
        ...(assembled ? { assembled_bytes: assembled } : {}), verified, ...(failure ? { error: failure.message } : {}) };
      report.reads.push(diagnostic);
      console.log(`Publication read: ${JSON.stringify(diagnostic)}`);
      fs.rmSync(downloaded, { force: true });
      fs.rmSync(headers, { force: true });
    }
  }
  async function github(file, immutable) {
    const name = path.basename(file), bytes = fs.readFileSync(file), sha = digest(bytes);
    let uncertain = false;
    await retry(`GitHub ${name}`, async () => {
      // Reconcile after a lost upload response before trying another upload.
      if (!assets || uncertain) await refreshAssets();
      const previous = assets.get(name);
      if (previous && previous.size === bytes.length && previous.digest === `sha256:${sha}`) {
        report.github_reused++;
        console.log(`Reused verified GitHub asset: ${name}`);
        return;
      }
      if (previous && immutable) {
        if (await read(file, origins[0], { fresh: false })) {
          report.github_reused++;
          return;
        }
      }
      uncertain = true;
      await run('gh', ['release', 'upload', release, file, '--repo', repo, ...(immutable ? [] : ['--clobber'])]);
      report.github_uploaded++;
      assets.set(name, { name, size: bytes.length, digest: `sha256:${sha}` });
      console.log(`Uploaded GitHub asset: ${name}`);
    }).catch(error => { throw Object.assign(new Error(`GitHub publication failed: ${name}; ${error.message}`, { cause: error }),
      { transient: Boolean(error.transient) }); });
  }
  async function mirror(file, immutable) {
    const name = path.basename(file);
    let uncertain = false;
    await cloudflareRetry(`Cloudflare ${name}`, async () => {
      // Reuse only after reading the complete object and verifying its SHA256.
      // This also resolves uploads that succeeded but lost their response.
      // SHA-addressed archives cannot change. Reuse their ordinary cache key
      // while still hashing every byte; unique queries force cold origin reads.
      // Mutable files and verification after an upload require a fresh read
      // (the ordinary URL may still have a cached pre-upload 404).
      if (await read(file, origins[1], { missing: true, different: !immutable, fresh: !immutable || uncertain, resume: immutable })) {
        report.cloudflare_reused++;
        console.log(`Reused verified Cloudflare object: ${name}`);
        return;
      }
      console.log(`Uploading Cloudflare object: ${name}`);
      uncertain = true;
      await run('aws', ['--endpoint-url', endpoint, 's3api', 'put-object', '--bucket', 'php-darwin',
        '--key', `extensions/${name}`, '--body', file,
        '--cache-control', immutable ? 'public, max-age=31536000, immutable' : 'no-cache, max-age=0, must-revalidate',
        '--cli-connect-timeout', '5', '--cli-read-timeout', '60'], { env });
      await read(file, origins[1], { resume: immutable });
      report.cloudflare_uploaded++;
      console.log(`Verified Cloudflare object: ${name}; SHA256 ${digest(fs.readFileSync(file))}`);
    }).catch(async error => {
      try {
        const object = JSON.parse(await run('aws', ['--endpoint-url', endpoint, 's3api', 'head-object',
          '--bucket', 'php-darwin', '--key', `extensions/${name}`, '--cli-connect-timeout', '5', '--cli-read-timeout', '30'], { env }));
        console.error(`R2 object exists: ${name}; ${object.ContentLength} bytes, ETag ${object.ETag}`);
      } catch { console.error(`R2 HeadObject could not confirm object: ${name}`); }
      throw Object.assign(new Error(`Cloudflare publication failed: ${name}; ${error.message}`, { cause: error }),
        { transient: Boolean(error.transient) });
    }).finally(() => fs.rmSync(path.join(directory, `verify-${name}.partial`), { force: true }));
  }
  return { github, mirror, report };
}
module.exports = { command, retryPolicy, httpError, readDiagnostic, githubJSON, workflowJobs, transfers };
