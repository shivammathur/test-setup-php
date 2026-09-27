const crypto = require('node:crypto');
const { Readable } = require('node:stream');

// A completed Actions job cannot become active again: reruns get new job IDs.
// Checking the owner job makes recovery safe even when a long compile blocks
// Node's event loop. A wall-clock lease alone could expire under a live build.
class SourceBuildLock {
  constructor(cache, { owner, now = Date.now, timeout = 180 * 60 * 1000 } = {}) {
    this.cache = cache;
    this.owner = owner;
    this.now = now;
    this.timeout = timeout;
  }

  async identity() {
    if (this.owner) return this.owner;
    const run = process.env.GITHUB_RUN_ID;
    const attempt = process.env.GITHUB_RUN_ATTEMPT;
    if (!/^\d+$/.test(run || '') || !/^\d+$/.test(attempt || '') || !process.env.RUNNER_NAME) {
      throw new Error('Source build coordination requires an Actions job identity');
    }
    for (let lookup = 0; lookup < 4; lookup++) {
      for (let page = 1; ; page++) {
        const result = await this.cache.api(`actions/runs/${run}/attempts/${attempt}/jobs?per_page=100&page=${page}`);
        const job = result.jobs.find(job => job.status === 'in_progress' && job.runner_name === process.env.RUNNER_NAME);
        if (job) return (this.owner = { job: job.id, run: Number(run), attempt: Number(attempt) });
        if (result.jobs.length < 100) break;
      }
      // Job state can briefly lag behind the runner starting its first step.
      if (lookup < 3) await this.cache.wait(2000 * (lookup + 1));
    }
    throw new Error('Could not identify the current source build job');
  }

  async acquire(key) {
    const hash = key.match(/^php-darwin-source-v1-([0-9a-f]{64})$/)?.[1];
    if (!hash) throw new Error('Invalid source build lock key');
    const owner = { ...await this.identity(), nonce: crypto.randomUUID() };
    const label = JSON.stringify(owner);
    const name = `source-build-lock-${hash}.json`;
    const release = await this.cache.release(true, this.cache.partition ? 'cache-locks' : this.cache.tag);
    const started = this.now();
    let announced = false;
    let failures = 0;
    let delay = 10000;
    while (this.now() - started < this.timeout) {
      try {
        let asset = (await this.cache.assets(release)).find(asset => asset.name === name);
        if (!asset) {
          const data = Buffer.from(label);
          await this.cache.transfer(
            `https://uploads.github.com/repos/${this.cache.repository}/releases/${release.id}/assets?` +
            new URLSearchParams({ name, label }), () => ({
              method: 'POST', headers: { Authorization: `Bearer ${this.cache.token}`,
                'Content-Type': 'application/json', 'Content-Length': String(data.length) },
              body: Readable.from([data]), duplex: 'half',
            }), async response => {
              await require('./source-bottle-releases.cjs').checkUploadResponse(response, 'Source build claim');
              if (!response.ok && response.status !== 422) {
                const error = new Error(`Source build claim on release ${release.id}: HTTP ${response.status}`);
                error.retryable = response.status === 404;
                throw error;
              }
            });
          asset = (await this.cache.assets(release)).find(asset => asset.name === name);
          if (!asset) {
            // A competing owner may finish between our 422 and this read. A new
            // successful upload may also need time to appear in the asset list.
            await this.cache.wait(1000);
            continue;
          }
        }
        let claimant;
        try { claimant = JSON.parse(asset.label); } catch { /* Foreign/malformed claims fail closed. */ }
        if (asset.state === 'uploaded' && claimant?.nonce === owner.nonce) {
          return { id: asset.id, waitedMs: this.now() - started };
        }
        if (claimant?.nonce === owner.nonce && asset.state === 'starter') {
          // This process owns the failed upload; no other builder can own it.
          await this.cache.api(`releases/assets/${asset.id}`, { method: 'DELETE', allow: [404] });
          continue;
        }
        if (!Number.isSafeInteger(claimant?.job) || claimant.job <= 0 ||
            !Number.isSafeInteger(claimant?.run) || claimant.run <= 0) {
          throw new Error(`Invalid source build owner for ${key}`);
        }
        const job = await this.cache.api(`actions/jobs/${claimant.job}`, { allow: [404] });
        const expired = this.now() - Date.parse(asset.created_at) >= this.timeout;
        if ((job?.run_id === claimant.run && job.status === 'completed') || (!job && expired)) {
          // Delete the immutable asset ID, never a name which a new owner could reuse.
          await this.cache.api(`releases/assets/${asset.id}`, { method: 'DELETE', allow: [404] });
          continue;
        }
        if (!announced) {
          this.cache.warn(`Waiting for source bottle ${key} owned by job ${claimant.job}`);
          announced = true;
        }
        failures = 0;
      } catch (error) {
        if (error.retryExhausted || ++failures >= 3) throw error;
        // An unavailable owner check is not evidence of an abandoned build.
        // Keep the claim intact, with at most three consecutive failed checks.
        this.cache.warn(`Source ownership check unavailable; retaining the claim for ${key}: ${error.message}`);
      }
      const remaining = this.timeout - (this.now() - started);
      if (remaining <= 0) break;
      await this.cache.wait(Math.min(delay, remaining));
      delay = Math.min(delay * 2, 60000);
    }
    throw new Error(`Timed out waiting for source build ${key}`);
  }

  async run(key, build) {
    const claim = await this.acquire(key);
    try { return await build(claim.waitedMs); }
    finally {
      try { await this.cache.api(`releases/assets/${claim.id}`, { method: 'DELETE', allow: [404] }); }
      catch (error) { this.cache.warn(`Could not release source build claim: ${error.message}`); }
    }
  }
}

module.exports = { SourceBuildLock };
