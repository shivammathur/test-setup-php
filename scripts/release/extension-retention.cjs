const {origins, validateEntry} = require('../installer/install-extensions.cjs');
const {command, githubJSON, retryPolicy, httpError} = require('./extension-transfers.cjs');

const archivePattern = /^(imagick|mongodb|memcached)-(5\.6|7\.[0-4]|8\.[0-7])-(debug|release)-(nts|zts)-(arm64|x86_64)-[a-f0-9]{64}\.tar\.zst$/;
const manifestPattern = /^extensions-(5\.6|7\.[0-4]|8\.[0-7])-manifest\.json$/;

function staleArchives(assets, objects, manifests, retained = []) {
  const live = new Set(retained);
  for (const {name, manifest} of manifests) {
    const match = manifestPattern.exec(name);
    if (!match || manifest.schema !== 1 || !Array.isArray(manifest.assets)) throw new Error('Invalid retention manifest');
    for (const entry of manifest.assets) {
      validateEntry(entry);
      if (entry.php_version !== match[1]) throw new Error('Retention manifest PHP version mismatch');
      live.add(entry.file);
    }
  }
  return [...new Set([...assets.map(asset => asset.name), ...objects])]
    .filter(name => archivePattern.test(name) && !live.has(name)).sort();
}

function retention({env, endpoint, run = command, retry = retryPolicy(), fetcher = fetch}) {
  const route = 'repos/shivammathur/php-darwin/releases';
  const aws = args => run('aws', ['--endpoint-url', endpoint, 's3api', ...args,
    '--bucket', 'php-darwin', '--cli-connect-timeout', '5', '--cli-read-timeout', '30'], {env});
  const report = {github_deleted: 0, cloudflare_deleted: 0, warnings: []};
  async function inventory() {
    const release = await githubJSON(`${route}/tags/extensions`, {run, retry});
    const assets = (await githubJSON(`${route}/${release.id}/assets?per_page=100`, {run, retry, paginate: true})).flat();
    const listing = await retry('List extension objects', async () =>
      JSON.parse(await aws(['list-objects-v2', '--prefix', 'extensions/'])));
    const objects = (listing.Contents || []).map(object => object.Key.replace(/^extensions\//, ''));
    return {assets, objects};
  }
  async function prune(retained = [], version) {
    const {assets, objects} = await inventory();
    const names = [...new Set([...assets.map(asset => asset.name), ...objects])].filter(name =>
      manifestPattern.test(name) && (!version || manifestPattern.exec(name)[1] === version));
    const manifests = [];
    // Read both commit points before deleting anything. A partial publication
    // may leave different manifests; every archive referenced by either lives.
    for (const name of names) {
      let found = false;
      for (const base of origins) {
        const manifest = await retry(`Read retention ${name}`, async () => {
          const response = await fetcher(`${base}/${name}?retention=${Date.now()}`, {signal: AbortSignal.timeout(30000), cache: 'no-store'});
          if (response.status === 404) { await response.body?.cancel(); return null; }
          if (!response.ok) { await response.body?.cancel(); throw httpError(response.status, 'Read retention manifest'); }
          return response.json();
        });
        if (manifest) { manifests.push({name, manifest}); found = true; }
      }
      if (!found) throw new Error(`Cannot read existing manifest ${name}`);
    }
    const eligible = name => !version || archivePattern.exec(name)?.[2] === version;
    const stale = staleArchives(assets.filter(asset => eligible(asset.name)), objects.filter(eligible), manifests, retained);
    const byName = new Map(assets.map(asset => [asset.name, asset]));
    for (const name of stale) {
      // R2 deletion is idempotent. Keep the GitHub inventory as a retry marker
      // until the corresponding object has also been removed.
      await retry(`Delete retired R2 object ${name}`, () => aws(['delete-object', '--key', `extensions/${name}`]));
      if (objects.includes(name)) report.cloudflare_deleted++;
      const asset = byName.get(name);
      if (asset) {
        await retry(`Delete retired GitHub asset ${name}`, () => run('gh', ['api', '--method', 'DELETE', `${route}/assets/${asset.id}`]));
        report.github_deleted++;
      }
    }
    return assets.filter(asset => !stale.includes(asset.name));
  }
  async function capacity(incoming) {
    let assets;
    try { assets = await prune(incoming); }
    catch (error) {
      report.warnings.push(error.message);
      console.warn(`Extension retention deferred: ${error.message}`);
      const release = await githubJSON(`${route}/tags/extensions`, {run, retry});
      assets = (await githubJSON(`${route}/${release.id}/assets?per_page=100`, {run, retry, paginate: true})).flat();
    }
    const total = new Set([...assets.map(asset => asset.name), ...incoming]).size;
    if (total > 1000) throw new Error(`Extension release needs ${total} assets; cleanup must complete before uploading`);
  }
  return {prune, capacity, report};
}
module.exports = {staleArchives, retention};
