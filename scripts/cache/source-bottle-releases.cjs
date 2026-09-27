const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { Readable } = require('node:stream');
const { curlRequest, errorDetails } = require('../lib/release-http.cjs');
const { pipeline, finished } = require('node:stream/promises');
const { spawnSync } = require('node:child_process');
const { setTimeout: pause } = require('node:timers/promises');
const { command, brewSource, readBottle, keyFor, validKey } = require('./source-bottle-cache.cjs');
const mirror = require('./source-bottle-mirror.cjs');
const { retryPolicy } = require('../release/extension-transfers.cjs');
const { releaseForFormula } = require('./source-cache-layout.cjs');

const sha256 = value => crypto.createHash('sha256').update(value).digest('hex');

function family(inputs) {
  return sha256(JSON.stringify({
    formula: inputs.formula, arch: inputs.environment.arch, macos: inputs.environment.macos,
    prefix: inputs.environment.prefix, build: inputs.context?.build, ts: inputs.context?.ts,
  }));
}

function releaseAsset(metadata) {
  const { inputs, key } = metadata;
  const hash = key.match(/^php-darwin-source-v1-([0-9a-f]{64})$/)?.[1];
  const variant = inputs.context ? `.${inputs.context.build}-${inputs.context.ts}` : '';
  const stem = `${inputs.formula.split('/').at(-1)}-${inputs.version}` +
    `.macos-${inputs.environment.macos}.${inputs.environment.arch}${variant}`;
  if (!hash || !/^[A-Za-z0-9@+_.-]+$/.test(stem)) throw new Error('Invalid source bottle asset name');
  // The index keeps versions unambiguous even when package names and versions
  // contain hyphens. GitHub displays the shorter, readable label.
  return { name: `${stem}.source-v2-${family(inputs)}.${inputs.version}.${hash}.tar`,
    label: `${stem}.${hash.slice(0, 12)}.tar` };
}

function assetIdentity(asset) {
  const indexed = asset.name.match(/^[A-Za-z0-9@+_.-]+\.source-v2-([0-9a-f]{64})\.([A-Za-z0-9+_.-]+)\.([0-9a-f]{64})\.tar$/);
  if (indexed) return { version: indexed[2], group: indexed[1], key: `php-darwin-source-v1-${indexed[3]}` };
  // Accept the previous double-hyphen filenames during migration.
  const match = asset.name.match(/^[A-Za-z0-9@+_.-]+--([A-Za-z0-9+_.-]+)\.macos-[0-9]+\.[A-Za-z0-9_.-]+\.source-v1-([0-9a-f]{64})\.([0-9a-f]{64})\.tar$/);
  if (match) return { version: match[1], group: match[2], key: `php-darwin-source-v1-${match[3]}` };
  // Read caches created before readable filenames were introduced.
  if (/^php-darwin-source-v1-[0-9a-f]{64}\.tar$/.test(asset.name)) {
    const label = asset.label?.match(/^source-v1:([0-9a-f]{64}):(.+)$/);
    return { key: asset.name.slice(0, -4), group: label?.[1], version: label?.[2] };
  }
}

function olderVersions(versions) {
  return JSON.parse(brewSource('prune', [JSON.stringify(versions)]));
}

function unpack(archive, directory, key) {
  const metadata = JSON.parse(command('tar', ['-xOf', archive, 'metadata.json']));
  if (metadata.key !== key || typeof metadata.file !== 'string' ||
    !/^[A-Za-z0-9@+_.-]+\.bottle(?:\.\d+)?\.tar\.gz$/.test(metadata.file)) {
    throw new Error('Invalid release bottle metadata');
  }
  fs.mkdirSync(directory, { recursive: true });
  // Extract only the two named files as byte streams. Archive paths and links
  // cannot write elsewhere on the runner.
  const output = fs.openSync(path.join(directory, metadata.file), 'w');
  try {
    const result = spawnSync('tar', ['-xOf', archive, metadata.file], { stdio: ['ignore', output, 'inherit'] });
    if (result.error || result.status !== 0) throw result.error || new Error('Could not extract source bottle');
  } finally { fs.closeSync(output); }
  fs.writeFileSync(path.join(directory, 'metadata.json'), JSON.stringify(metadata));
  readBottle(directory, key);
}

class ReleaseCache {
  constructor({ repository = process.env.GITHUB_REPOSITORY, token = process.env.GH_TOKEN,
    tag = 'cache', partition = tag === 'cache', request = fetch, fallbackRequest = request === fetch ? curlRequest : undefined,
    mirrorDownload = request === fetch ? mirror.transfer : undefined,
    mirrorMissFile = process.env.PHP_DARWIN_SOURCE_BOTTLE_MISSES,
    dependencyLockFile,
    versionsToPrune = olderVersions, wait = pause, warn = console.warn } = {}) {
    if (!/^shivammathur\/[A-Za-z0-9_.-]+$/.test(repository || '') || !token) {
      throw new Error('Release source cache requires a shivammathur repository and GH_TOKEN');
    }
    this.repository = repository;
    this.token = token;
    this.tag = tag;
    this.partition = partition;
    this.request = request;
    this.fallbackRequest = fallbackRequest;
    this.mirrorDownload = mirrorDownload;
    this.mirrorMissFile = mirrorMissFile;
    this.dependencyLockFile = dependencyLockFile;
    this.versionsToPrune = versionsToPrune;
    this.wait = wait;
    this.mirrorRetry = retryPolicy({ wait });
    this.warn = warn;
    this.responses = new Map();
  }

  async transfer(url, optionsForAttempt, consume, timeout = 30000) {
    for (let attempt = 1; ; attempt++) {
      const options = optionsForAttempt();
      let response;
      let delay;
      try {
        const request = this.useFallback ? this.fallbackRequest : this.request;
        response = await request(url, { ...options, signal: AbortSignal.timeout(timeout) });
        if ([408, 429, 500, 502, 503, 504].includes(response.status) ||
          (response.status === 403 && (response.headers.has('retry-after') ||
            response.headers.get('x-ratelimit-remaining') === '0'))) {
          const error = new Error(`Release cache request: HTTP ${response.status}`);
          error.retryable = true;
          throw error;
        }
        return await consume(response);
      } catch (error) {
        if (attempt === 3) {
          // Keep the original failure without mutating read-only DOMExceptions.
          const failure = new Error(errorDetails(error), { cause: error });
          failure.name = error.name;
          failure.code = error.code;
          failure.retryable = true;
          failure.retryExhausted = true;
          throw failure;
        }
        if (this.fallbackRequest && !this.useFallback &&
            (!response || ['TypeError', 'AbortError', 'TimeoutError'].includes(error.name))) {
          this.useFallback = true;
          this.warn(`Switching release requests to curl after Node HTTP failed: ${errorDetails(error)}`);
        }
        const retryAfter = response?.headers.get('retry-after');
        const reset = response?.headers.get('x-ratelimit-reset');
        const serverDelay = retryAfter ? (Number.isFinite(Number(retryAfter)) ? Number(retryAfter) * 1000 : Date.parse(retryAfter) - Date.now()) :
          (response?.headers.get('x-ratelimit-remaining') === '0' && reset ? Number(reset) * 1000 - Date.now() : 0);
        delay = Math.min(60000, Math.max(1000 * 2 ** (attempt - 1), serverDelay || 0));
        this.warn(`Retrying release cache request (${attempt + 1}/3) in ${delay / 1000}s: ${errorDetails(error)}`);
      } finally {
        // Recreate upload streams on retry and release unused error bodies.
        if (options.body?.destroy) {
          options.body.destroy();
          await finished(options.body, { cleanup: true }).catch(() => {});
        }
        if (response?.body && !response.bodyUsed) await response.body.cancel().catch(() => {});
      }
      await this.wait(delay);
    }
  }

  async api(endpoint, { method = 'GET', body, binary = false, accept, allow = [], consume } = {}) {
    const cached = method === 'GET' && !binary ? this.responses.get(endpoint) : undefined;
    return this.transfer(`https://api.github.com/repos/${this.repository}/${endpoint}`, () => ({
      method, headers: { Authorization: `Bearer ${this.token}`,
        Accept: accept || (binary ? 'application/octet-stream' : 'application/vnd.github+json'),
        ...(cached ? { 'If-None-Match': cached.etag } : {}),
        'X-GitHub-Api-Version': '2022-11-28', ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    }), async response => {
      // GitHub revalidates the state; a 304 does not consume the primary API
      // quota. Ownership polling must never substitute a time-based local cache.
      if (response.status === 304 && cached) return cached.value;
      if (allow.includes(response.status)) {
        this.responses.delete(endpoint);
        return null;
      }
      if (!response.ok) throw new Error(`Release cache ${method} ${endpoint}: HTTP ${response.status}`);
      if (binary) return consume(response);
      const value = response.status === 204 ? null : await response.json();
      if (method === 'GET' && response.headers.has('etag')) {
        this.responses.set(endpoint, { etag: response.headers.get('etag'), value });
      } else if (method === 'GET') this.responses.delete(endpoint);
      return value;
    }, binary ? 300000 : 30000);
  }

  bottleTag(inputs) {
    return this.partition ? releaseForFormula(inputs.formula) : this.tag;
  }

  async release(create = false, tag = this.tag) {
    let release = await this.api(`releases/tags/${encodeURIComponent(tag)}`, { allow: [404] });
    if (!release && create) {
      release = await this.api('releases', { method: 'POST', allow: [422], body: {
        tag_name: tag, target_commitish: process.env.GITHUB_SHA || 'main', name: tag,
        body: 'Homebrew source bottles and build-input metadata used by PHP cache builds.',
        prerelease: tag.startsWith('source-bottles-test-'),
        draft: tag.startsWith('source-bottles-test-'), make_latest: 'false',
      } });
      release ||= await this.api(`releases/tags/${encodeURIComponent(tag)}`);
    }
    return release;
  }

  async assets(release) {
    const assets = [];
    for (let page = 1; ; page++) {
      const batch = await this.api(`releases/${release.id}/assets?per_page=100&page=${page}`);
      assets.push(...batch);
      if (batch.length < 100) return assets;
    }
  }

  async removeAbandonedUpload(release, name) {
    // A failed GitHub upload can reserve a name with an empty "starter"
    // asset. Wait longer than all bounded upload attempts before removing it
    // so another runner still uploading this key is not interrupted.
    const abandoned = asset => asset?.name === name && asset.state === 'starter' &&
      asset.size === 0 && Date.now() - Date.parse(asset.created_at) >= 30 * 60 * 1000;
    const pending = (await this.assets(release)).find(abandoned);
    if (!pending) return;
    const current = await this.api(`releases/assets/${pending.id}`, { allow: [404] });
    if (abandoned(current)) {
      await this.api(`releases/assets/${pending.id}`, { method: 'DELETE', allow: [404] });
    }
  }

  async download(asset, directory, key, { useMirror = true, tag = this.tag } = {}) {
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'source-bottle-download-'));
    try {
      const archive = path.join(temporary, 'bundle.tar');
      const mirrored = useMirror && this.mirrorDownload && mirror.record(asset, this.repository, tag);
      if (mirrored) {
        try {
          const status = await this.mirrorRetry('Cloudflare source bottle read', async () => {
            const response = await this.mirrorDownload(mirror.publicURL(mirrored), archive);
            if (response === 404) return response;
            if (response !== 200 || !await mirror.validFile(archive, mirrored.sha256)) {
              throw new Error(`Cloudflare source bottle rejected: ${mirrored.formula} (HTTP ${response})`);
            }
            return response;
          });
          if (status === 200) {
            unpack(archive, directory, key);
            console.log(`Cloudflare source bottle HIT: ${mirrored.formula} ${mirrored.version}`);
            return;
          }
          if (status !== 404) this.warn(`Cloudflare source bottle rejected: ${mirrored.formula} (HTTP ${status})`);
        } catch (error) {
          this.warn(`Cloudflare source bottle unavailable: ${mirrored.formula}: ${errorDetails(error)}`);
        }
        mirror.queue(mirrored, this.mirrorMissFile);
        console.log(`Cloudflare source bottle MISS: ${mirrored.formula}; using GitHub fallback and queued for caching`);
        fs.rmSync(archive, { force: true });
      }
      await this.api(`releases/assets/${asset.id}`, { binary: true, consume: async response => {
        await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(archive));
        if (asset.digest && asset.digest !== `sha256:${sha256(fs.readFileSync(archive))}`) {
          throw new Error('Release source cache archive checksum mismatch');
        }
      } });
      unpack(archive, directory, key);
    } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
  }

  async restoreCache([directory], key, _restoreKeys = [], inputs) {
    if (this.partition && (!inputs || !validKey(inputs, key))) throw new Error('Source cache lookup requires matching build inputs');
    const tags = this.partition ? [...new Set([this.bottleTag(inputs), this.tag,
      `cache-source-${family(inputs).slice(0, 2)}`])] : [this.tag];
    this.lastLookup = { key, assets: [] };
    for (const tag of tags) {
      const release = await this.release(false, tag);
      if (!release) continue;
      const assets = await this.assets(release);
      this.lastLookup.assets.push(...assets);
      const asset = assets.find(asset => asset.state !== 'starter' && assetIdentity(asset)?.key === key);
      if (asset) {
        await this.download(asset, directory, key, { tag });
        return key;
      }
      if (!inputs || keyFor(inputs) !== key) continue;
      // Older caches hashed recipe bytes and compiler details. Reuse only a
      // checksum-verified bottle with the same software versions and target.
      const candidates = assets.filter(item => {
        const identity = assetIdentity(item);
        return item.state !== 'starter' && identity?.group === family(inputs) && identity.version === inputs.version;
      }).sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at)).slice(0, 3);
      for (const candidate of candidates) {
        const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'source-bottle-legacy-'));
        try {
          const oldKey = assetIdentity(candidate).key;
          await this.download(candidate, temporary, oldKey, {tag});
          const metadata = JSON.parse(fs.readFileSync(path.join(temporary, 'metadata.json')));
          if (!metadata.inputs || !validKey(metadata.inputs, oldKey)) continue;
          const previous = {...metadata.inputs};
          // Legacy nightly PHP keys recorded the complete source recipe hash.
          // An identical recipe proves the source commit when it was not yet
          // recorded separately; never equate two nightlies by semver alone.
          if (!previous.source_commit && inputs.source_commit && previous.recipe === inputs.recipe) {
            previous.source_commit = inputs.source_commit;
          }
          if (keyFor(previous) !== key) continue;
          fs.mkdirSync(directory, {recursive: true});
          fs.copyFileSync(path.join(temporary, metadata.file), path.join(directory, metadata.file));
          // This is a local alias only: leave the original release and mirror intact.
          fs.writeFileSync(path.join(directory, 'metadata.json'), JSON.stringify({...metadata, key, inputs: previous}));
          readBottle(directory, key);
          return key;
        } catch (error) { this.warn(`Ignoring incompatible source bottle ${candidate.id}: ${error.message}`); }
        finally { fs.rmSync(temporary, {recursive: true, force: true}); }
      }
    }
  }

  missReason(key, inputs) {
    if (this.lastLookup?.key !== key) return 'first-build';
    const related = this.lastLookup.assets.map(assetIdentity).filter(item => item?.group === family(inputs));
    if (!related.length) return 'first-build';
    return related.some(item => item.version === inputs.version) ? 'build-inputs-changed' : 'new-package-version';
  }

  async withBuildLock(key, build) {
    const { SourceBuildLock } = require('./source-build-lock.cjs');
    this.buildLock ||= new SourceBuildLock(this);
    return this.buildLock.run(key, build);
  }

  async saveCache([directory], key) {
    readBottle(directory, key);
    const metadata = JSON.parse(fs.readFileSync(path.join(directory, 'metadata.json')));
    const group = family(metadata.inputs);
    const { name, label } = releaseAsset(metadata);
    const tag = this.bottleTag(metadata.inputs);
    const release = await this.release(true, tag);
    await this.removeAbandonedUpload(release, name);
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'source-bottle-upload-'));
    try {
      const archive = path.join(temporary, `${key}.tar`);
      command('tar', ['-cf', archive, '-C', path.resolve(directory), 'metadata.json', metadata.file]);
      const archiveSize = fs.statSync(archive).size;
      const archiveDigest = `sha256:${sha256(fs.readFileSync(archive))}`;
      // Upload metadata and the bottle together. A concurrent upload may win
      // this exact key; never clobber it or expose a separate pair of files.
      await this.transfer(
        `https://uploads.github.com/repos/${this.repository}/releases/${release.id}/assets?` +
        new URLSearchParams({ name, label }), () => ({
          method: 'POST', headers: { Authorization: `Bearer ${this.token}`, 'Content-Type': 'application/x-tar',
            'Content-Length': String(archiveSize) },
          body: fs.createReadStream(archive), duplex: 'half',
        }), async response => {
          await checkUploadResponse(response, 'Source bottle upload');
          if (!response.ok && response.status !== 422) {
            const error = new Error(`Source bottle upload: HTTP ${response.status}`);
            // GitHub can also return 404 when concurrent uploads race with
            // deletion, or before a new release reaches uploads.github.com.
            error.retryable = response.status === 404;
            throw error;
          }
        }, 300000);
      const assets = await this.assets(release);
      const saved = assets.find(asset => asset.name === name);
      if (!saved) throw new Error('Uploaded source bottle is missing');
      // GitHub hashes the stored upload. Comparing that digest and byte count
      // with the locally verified bundle proves it arrived intact without a
      // redundant CDN download that keeps every waiting builder locked out.
      if (saved.state === 'uploaded' && saved.size === archiveSize && saved.digest === archiveDigest) {
        console.log(`Verified uploaded source bottle by GitHub SHA-256: ${metadata.inputs.formula} ${metadata.inputs.version}`);
      } else {
        // Legacy servers may omit digests, and a concurrent winner can have a
        // different tar encoding. Fully validate those bytes before pruning.
        await this.download(saved, path.join(temporary, 'verified'), key, { tag });
      }
      const mirrored = mirror.record(saved, this.repository, tag);
      if (mirrored) mirror.queue(mirrored, this.mirrorMissFile);
      const related = assets.map(asset => ({ asset, identity: assetIdentity(asset) }))
        .filter(entry => entry.identity?.group === group);
      const obsolete = this.versionsToPrune(related.map(entry => entry.identity.version));
      // Preparing a new dependency generation must not remove the bottles
      // still selected by ordinary cache jobs before promotion succeeds.
      const protectedKeys = require('./approved-dependencies.cjs').protectedSourceKeys(this.dependencyLockFile);
      if (obsolete.includes(metadata.inputs.version)) {
        // An older job can finish after a newer upload. Verify that replacement
        // too; its own uploader may have failed before completing read-back.
        const newer = related.find(entry => !obsolete.includes(entry.identity.version));
        await this.download(newer.asset, path.join(temporary, 'replacement'), newer.identity.key, { tag });
      }
      for (const { asset, identity } of related) {
        if (obsolete.includes(identity.version) && !protectedKeys.has(identity.key)) {
          await this.api(`releases/assets/${asset.id}`, { method: 'DELETE', allow: [404] });
        }
      }
    } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
  }
}

async function checkUploadResponse(response, operation) {
  if (response.status !== 422) return;
  const details = await response.text();
  let errors;
  try { errors = JSON.parse(details).errors; } catch { /* Unknown validation errors must fail closed. */ }
  if (errors?.length && errors.every(error => error.resource === 'ReleaseAsset' &&
      error.field === 'name' && error.code === 'already_exists')) return;
  throw new Error(`${operation}: HTTP 422 ${details}`);
}

module.exports = { ReleaseCache, family, releaseAsset, assetIdentity, unpack, checkUploadResponse };
