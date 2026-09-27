const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { ReleaseCache } = require('../../cache/source-bottle-releases.cjs');
const { SourceBuildLock } = require('../../cache/source-build-lock.cjs');

async function main() {
  const tag = process.env.CACHE_RELEASE;
  if (!tag?.startsWith('source-bottles-test-')) throw new Error('Live coordination tests require an isolated test release');
  const cache = new ReleaseCache({ tag });
  cache.request = async () => { throw new TypeError('Simulated Node connection failure'); };
  const key = 'php-darwin-source-v1-' + crypto.createHash('sha256')
    .update(`${process.env.GITHUB_RUN_ID}:${process.env.RUNNER_ARCH}:coordination`).digest('hex');
  let active = 0;
  let compiled = 0;
  let restored = 0;
  let cached = false;
  await Promise.all([1, 2, 3].map(async () => {
    const lock = new SourceBuildLock(cache);
    await lock.run(key, async () => {
      assert.equal(++active, 1, 'two workers acquired the same source key');
      try {
        if (cached) restored++;
        else {
          compiled++;
          const asset = (await cache.assets(await cache.release()))
            .find(item => item.name === `source-build-lock-${key.slice(-64)}.json`);
          const downloaded = await cache.api(`releases/assets/${asset.id}`, {
            binary: true, consume: response => response.json(),
          });
          assert.deepEqual(downloaded, JSON.parse(asset.label));
          await new Promise(resolve => setTimeout(resolve, 1500));
          cached = true;
        }
      } finally { active--; }
    });
  }));
  assert.equal(compiled, 1);
  assert.equal(restored, 2);
  assert.equal(cache.useFallback, true);
  const release = await cache.release();
  assert.ok(!(await cache.assets(release)).some(asset => asset.name === `source-build-lock-${key.slice(-64)}.json`));
  console.log('Live source coordination passed through curl fallback: one builder, two reusers, verified asset download, no remaining claim');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
