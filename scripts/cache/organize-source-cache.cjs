const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { setTimeout: pause } = require('node:timers/promises');
const { curlRequest } = require('../lib/release-http.cjs');
const { ReleaseCache, assetIdentity, unpack, family, checkUploadResponse } = require('./source-bottle-releases.cjs');
const { validKey } = require('./source-bottle-cache.cjs');
const { releaseForFormula, legacyRelease } = require('./source-cache-layout.cjs');
const mirror = require('./source-bottle-mirror.cjs');

// Bulk migration can issue hundreds of writes. Share one pacing queue across
// both transports, and stop all workers on a quota response instead of retrying
// before GitHub's reset. Normal build and installer transports are unchanged.
function migrationTransport({ request = fetch, fallback = curlRequest, wait = pause, now = Date.now } = {}) {
  let writes = Promise.resolve(), nextWrite = 0, blocked;
  const wrap = transport => async (url, options = {}) => {
    if (blocked) throw blocked;
    if (!['GET', 'HEAD', 'OPTIONS'].includes(options.method || 'GET')) {
      const turn = writes.then(async () => {
        if (blocked) throw blocked;
        await wait(Math.max(0, nextWrite - now()));
        nextWrite = now() + 1000;
      });
      writes = turn.catch(() => {});
      await turn;
    }
    if (blocked) throw blocked;
    const response = await transport(url, options);
    const remaining = response.headers.get('x-ratelimit-remaining');
    if ([403, 429].includes(response.status) || remaining === '0') {
      const reset = Number(response.headers.get('x-ratelimit-reset')) * 1000;
      const retryAfter = response.headers.get('retry-after');
      const retryTime = retryAfter && (Number.isFinite(Number(retryAfter)) ? now() + Number(retryAfter) * 1000 : Date.parse(retryAfter));
      const resume = remaining === '0' && reset > now() ? reset : retryTime || now() + 60000;
      blocked = new Error(`Migration stopped: HTTP ${response.status}, API quota ${remaining ?? 'unknown'}/` +
        `${response.headers.get('x-ratelimit-limit') ?? 'unknown'}; resume after ${new Date(resume).toISOString()}. ` +
        'Verified destination copies are retained.');
      if (!response.ok) {
        const body = await response.text();
        try { blocked.message += ` GitHub: ${JSON.parse(body).message}`; } catch { /* Headers retain the useful quota details. */ }
        throw blocked;
      }
    }
    return response;
  };
  return { request: wrap(request), fallbackRequest: wrap(fallback), mirrorDownload: mirror.transfer };
}

function placement(asset, source) {
  const identity = assetIdentity(asset);
  const marker = identity && `-${identity.version}.macos-`;
  const pieces = marker && asset.name.split(marker);
  if (!identity || pieces.length !== 2 || !/^[A-Za-z0-9@+_.-]+$/.test(pieces[0]) ||
      asset.state !== 'uploaded' || !/^sha256:[0-9a-f]{64}$/.test(asset.digest || '') ||
      !Number.isSafeInteger(asset.id) || !Number.isSafeInteger(asset.size) || asset.size <= 0) {
    throw new Error(`Cannot safely classify source asset ${asset.name}`);
  }
  return { asset, source, target: releaseForFormula(pieces[0]), identity };
}

function matches(actual, expected) {
  return actual?.state === 'uploaded' && actual.name === expected.name &&
    actual.size === expected.size && actual.digest === expected.digest;
}

async function inventory(cache) {
  const releases = [];
  for (let page = 1; ; page++) {
    const batch = await cache.api(`releases?per_page=100&page=${page}`);
    releases.push(...batch.filter(r => r.tag_name === 'cache' || legacyRelease(r.tag_name)));
    if (batch.length < 100) break;
  }
  const entries = [], locks = [], keys = new Set();
  for (const release of releases) {
    for (const asset of await cache.assets(release)) {
      if (/^source-build-lock-[0-9a-f]{64}\.json$/.test(asset.name)) {
        locks.push(asset); continue;
      }
      const entry = placement(asset, release.tag_name);
      if (keys.has(entry.identity.key)) throw new Error(`Duplicate source key: ${entry.identity.key}`);
      keys.add(entry.identity.key); entries.push(entry);
    }
  }
  return { releases, entries, locks };
}

async function workers(values, action, concurrency = 4) {
  let next = 0, failure;
  await Promise.all(Array.from({ length: Math.min(concurrency, values.length) }, async () => {
    while (!failure && next < values.length) {
      const value = values[next++];
      try { await action(value); } catch (error) { failure ||= error; }
    }
  }));
  if (failure) throw failure;
}

async function completedClaim(cache, asset) {
  let owner;
  try { owner = JSON.parse(asset.label); } catch { /* Refuse unknown claims. */ }
  if (!Number.isSafeInteger(owner?.job) || !Number.isSafeInteger(owner?.run)) return false;
  const job = await cache.api(`actions/jobs/${owner.job}`, { allow: [404] });
  if (!job && Date.now() - Date.parse(asset.created_at) >= 180 * 60 * 1000) {
    return !await cache.api(`actions/runs/${owner.run}`, { allow: [404] });
  }
  return job?.run_id === owner.run && job.status === 'completed';
}

async function noActiveClaims(cache, oldClaims) {
  const release = await cache.release(false, 'cache-locks');
  const claims = [...oldClaims, ...(release ? await cache.assets(release) : [])];
  for (const asset of claims) {
    if (!await completedClaim(cache, asset)) throw new Error(`Source build claim is still active or unknown: ${asset.name}`);
  }
}

async function copy(cache, entry, release, existing, { mirrorDownload = mirror.transfer } = {}) {
  const { asset, source, target, identity } = entry;
  const current = existing.get(asset.name);
  if (current) {
    if (!matches(current, asset)) throw new Error(`Destination differs: ${target}/${asset.name}`);
    return { target, name: asset.name, id: current.id, result: 'existing' };
  }
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'organize-source-cache-'));
  try {
    const archive = path.join(temporary, 'bundle.tar');
    const record = mirror.record(asset, cache.repository, source);
    let mirrored = false;
    if (record) {
      try {
        mirrored = await mirrorDownload(mirror.publicURL(record), archive) === 200 &&
          await mirror.validFile(archive, asset.digest.slice(7));
      } catch (error) { cache.warn(`Cloudflare migration read unavailable: ${error.message}`); }
    }
    if (!mirrored) await cache.api(`releases/assets/${asset.id}`, { binary: true,
      consume: response => pipeline(Readable.fromWeb(response.body), fs.createWriteStream(archive)) });
    if (fs.statSync(archive).size !== asset.size || !await mirror.validFile(archive, asset.digest.slice(7))) {
      throw new Error(`Source bytes differ: ${asset.name}`);
    }
    const verified = path.join(temporary, 'verified');
    unpack(archive, verified, identity.key);
    const metadata = JSON.parse(fs.readFileSync(path.join(verified, 'metadata.json')));
    if (!validKey(metadata.inputs, identity.key) || family(metadata.inputs) !== identity.group ||
        metadata.inputs.version !== identity.version || releaseForFormula(metadata.inputs.formula) !== target) {
      throw new Error(`Source metadata differs: ${asset.name}`);
    }
    const uploaded = await cache.transfer(
      `https://uploads.github.com/repos/${cache.repository}/releases/${release.id}/assets?` +
      new URLSearchParams({ name: asset.name, label: asset.label || asset.name }), () => ({
        method: 'POST', headers: { Authorization: `Bearer ${cache.token}`, 'Content-Type': 'application/x-tar',
          'Content-Length': String(asset.size) }, body: fs.createReadStream(archive), duplex: 'half',
      }), async response => {
        await checkUploadResponse(response, 'Source cache migration upload');
        if (response.status === 422) return null;
        if (!response.ok) throw new Error(`Migration upload: HTTP ${response.status}`);
        return response.json();
      }, 300000);
    const saved = uploaded ? await cache.api(`releases/assets/${uploaded.id}`) :
      (await cache.assets(release)).find(item => item.name === asset.name);
    if (!matches(saved, asset)) throw new Error(`Destination verification failed: ${asset.name}`);
    existing.set(saved.name, saved);
    return { target, name: asset.name, id: saved.id, result: 'copied' };
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
}

async function verifyDestinations(cache, entries) {
  const targets = new Map();
  for (const entry of entries) {
    if (!targets.has(entry.target)) {
      const release = await cache.release(false, entry.target);
      if (!release) throw new Error(`Missing destination release: ${entry.target}`);
      targets.set(entry.target, new Map((await cache.assets(release)).map(a => [a.name, a])));
    }
    if (!matches(targets.get(entry.target).get(entry.asset.name), entry.asset)) {
      throw new Error(`Destination verification failed: ${entry.target}/${entry.asset.name}`);
    }
  }
}

async function removeCopies(cache, entries) {
  await verifyDestinations(cache, entries);
  await workers(entries, async entry => {
    const current = await cache.api(`releases/assets/${entry.asset.id}`, { allow: [404] });
    if (!current) return;
    if (!matches(current, entry.asset)) throw new Error(`Original asset changed: ${entry.asset.name}`);
    await cache.api(`releases/assets/${entry.asset.id}`, { method: 'DELETE' });
  });
}

async function migrate(cache, plan, { report = () => {}, copyEntry = copy } = {}) {
  await noActiveClaims(cache, plan.locks);
  const destinations = new Map(), results = [];
  const copyEntries = async entries => {
    for (const tag of new Set(entries.map(entry => entry.target))) {
      const release = await cache.release(true, tag);
      destinations.set(tag, { release, assets: new Map((await cache.assets(release)).map(a => [a.name, a])) });
    }
    await workers(entries, async entry => {
      const destination = destinations.get(entry.target);
      results.push(await copyEntry(cache, entry, destination.release, destination.assets));
      report(results);
      if (results.length % 25 === 0) console.log(`Verified ${results.length} migrated source bottles`);
    });
  };
  // Move PHP/extensions first, freeing the full legacy release before returning
  // shared libraries from the old shards to cache. Originals survive copy failure.
  const builds = plan.entries.filter(e => e.target !== 'cache' && e.target !== e.source);
  await copyEntries(builds);
  await noActiveClaims(cache, plan.locks);
  await removeCopies(cache, builds);
  const dependencies = plan.entries.filter(e => e.target === 'cache' && e.source !== 'cache');
  await copyEntries(dependencies);
  await noActiveClaims(cache, plan.locks);
  await removeCopies(cache, dependencies);
  await verifyDestinations(cache, plan.entries);
  for (const asset of plan.locks) {
    if (!await completedClaim(cache, asset)) throw new Error(`Refusing to remove live claim ${asset.id}`);
    await cache.api(`releases/assets/${asset.id}`, { method: 'DELETE', allow: [404] });
  }
  for (const release of plan.releases.filter(r => legacyRelease(r.tag_name))) {
    if ((await cache.assets(release)).length) throw new Error(`Legacy release is not empty: ${release.tag_name}`);
    await cache.api(`releases/${release.id}`, { method: 'DELETE' });
  }
  // A previous cleanup may have deleted a release before its tag deletion
  // completed. Reconcile those refs as well, without touching any other tag.
  const refs = await cache.api('git/matching-refs/tags/cache-source-');
  for (const ref of refs) {
    const tag = ref.ref.replace(/^refs\/tags\//, '');
    if (!legacyRelease(tag)) continue;
    if (await cache.release(false, tag)) throw new Error(`Legacy release still exists: ${tag}`);
    await cache.api(`git/refs/tags/${tag}`, { method: 'DELETE', allow: [404] });
  }
  return results;
}

async function main() {
  if (process.env.GITHUB_REPOSITORY !== 'shivammathur/php-darwin') throw new Error('Unexpected migration repository');
  const cache = new ReleaseCache(migrationTransport());
  const response = await cache.request('https://api.github.com/rate_limit', {
    headers: { Authorization: `Bearer ${cache.token}`, Accept: 'application/vnd.github+json' },
    signal: AbortSignal.timeout(30000),
  });
  const quota = (await response.json()).resources.core;
  console.log(`GitHub API budget: ${quota.remaining}/${quota.limit}; resets ${new Date(quota.reset * 1000).toISOString()}`);
  const plan = await inventory(cache);
  fs.writeFileSync('source-cache-plan.json', JSON.stringify(plan, null, 2));
  const counts = {};
  for (const entry of plan.entries) counts[entry.target] = (counts[entry.target] || 0) + 1;
  console.log(JSON.stringify(counts, null, 2));
  if (process.env.APPLY !== 'true') return;
  const results = await migrate(cache, plan, { report: results =>
    fs.writeFileSync('source-cache-migration.json', JSON.stringify(results, null, 2)) });
  console.log(`Verified ${plan.entries.length} source bottles; ${results.length} moved or resumed; removed empty legacy shards`);
}
module.exports = { placement, matches, inventory, workers, noActiveClaims, copy, verifyDestinations, removeCopies, migrate, migrationTransport };
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });
