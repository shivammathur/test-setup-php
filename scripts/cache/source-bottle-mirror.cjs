// Build-time source bottles only. Runtime PHP installs keep their own origin policy.
const fs = require('node:fs');
const { transfer, validFile, publish, readRecords } = require('./upstream-bottle-cache.cjs');
const { command } = require('./source-bottle-cache.cjs');
const repository = 'shivammathur/php-darwin';
const tag = 'cache';
const { productionRelease, legacyRelease, releaseForFormula } = require('./source-cache-layout.cjs');

function record(asset, repo = repository, release = tag) {
  if (repo !== repository || !(productionRelease(release) || legacyRelease(release))) return;
  const identity = require('./source-bottle-releases.cjs').assetIdentity(asset);
  if (!identity || !/^sha256:[0-9a-f]{64}$/.test(asset.digest || '') ||
      asset.state === 'starter' || !Number.isSafeInteger(asset.size) || asset.size <= 0) return;
  const stem = asset.name.split(`-${identity.version}.macos-`);
  if (stem.length !== 2 || !/^[A-Za-z0-9@+_.-]+$/.test(stem[0])) return;
  if (release !== tag && !legacyRelease(release) && release !== releaseForFormula(stem[0])) return;
  return portable({ formula: stem[0], version: identity.version, tag: 'source',
    name: asset.name, source_key: identity.key, bytes: asset.size,
    sha256: asset.digest.slice(7),
    url: `https://github.com/${repository}/releases/download/${release}/${encodeURIComponent(asset.name)}` });
}

function portable(value) {
  const release = typeof value?.url === 'string' ? value.url.split('/')[7] : '';
  if (!value || !/^[A-Za-z0-9@+_.-]+$/.test(value.formula || '') ||
      !/^[A-Za-z0-9+_.-]+$/.test(value.version || '') || value.tag !== 'source' ||
      !/^[0-9a-f]{64}$/.test(value.sha256 || '') ||
      !Number.isSafeInteger(value.bytes) || value.bytes <= 0 ||
      !/^[A-Za-z0-9@+_.-]+\.tar$/.test(value.name || '') ||
      !/^php-darwin-source-v1-[0-9a-f]{64}$/.test(value.source_key || '') ||
      !value.name.startsWith(`${value.formula}-${value.version}.macos-`) ||
      !(release === tag || legacyRelease(release) || release === releaseForFormula(value.formula)) ||
      value.url !== `https://github.com/${repository}/releases/download/${release}/${encodeURIComponent(value.name)}` ||
      require('./source-bottle-releases.cjs').assetIdentity(value)?.key !== value.source_key ||
      require('./source-bottle-releases.cjs').assetIdentity(value)?.version !== value.version) {
    throw new Error('Invalid mirrored source bottle identity');
  }
  const { formula, version, tag: kind, name, source_key, bytes, sha256, url } = value;
  return { formula, version, tag: kind, name, source_key, bytes, sha256, url };
}

function key(value) { return `homebrew/source-bottles/sha256/${portable(value).sha256}.tar`; }
function publicURL(value) { return `https://artifacts.php-darwin.setup-php.com/${key(value)}`; }
function queue(value, file = process.env.PHP_DARWIN_SOURCE_BOTTLE_MISSES) {
  if (file) fs.appendFileSync(file, JSON.stringify(portable(value)) + '\n');
}
function matrix(records, formula = '') {
  if (formula && !/^[A-Za-z0-9@+_.-]+$/.test(formula)) throw new Error('Invalid source dependency name');
  const groups = new Map();
  for (const input of records) {
    const value = portable(input);
    if (formula && value.formula !== formula) continue;
    if (!groups.has(value.formula)) groups.set(value.formula, new Map());
    groups.get(value.formula).set(value.sha256, value);
  }
  if (formula && !groups.size) throw new Error(`No cached source bottles for ${formula}`);
  if (groups.size > 256) throw new Error('Source bottle matrix exceeds 256 dependencies');
  return { include: [...groups].sort(([a], [b]) => a.localeCompare(b)).map(([formula, values]) => ({
    formula, bottles: [...values.values()],
  })) };
}
async function main() {
  if (process.argv[2] === 'matrix') {
    let records;
    if (process.env.SEED === 'true') {
      const releases = JSON.parse(command('gh', ['api', '--paginate', '--slurp',
        `repos/${repository}/releases?per_page=100`])).flat().filter(item => productionRelease(item.tag_name));
      records = releases.flatMap(release => {
        const pages = JSON.parse(command('gh', ['api', '--paginate', '--slurp',
          `repos/${repository}/releases/${release.id}/assets?per_page=100`]));
        return pages.flat().map(asset => record(asset, repository, release.tag_name)).filter(Boolean);
      });
    } else records = readRecords(process.argv[3]);
    const result = matrix(records, process.env.FORMULA || '');
    fs.writeFileSync('source-bottle-matrix.json', JSON.stringify(result, null, 2));
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `matrix=${JSON.stringify(result)}\ncount=${result.include.length}\n`);
    console.log(`${result.include.length} source dependency jobs; ${result.include.reduce((n, item) => n + item.bottles.length, 0)} exact bottles`);
  } else if (process.argv[2] === 'publish') {
    const results = await publish(JSON.parse(process.env.BOTTLES), {
      identity: portable, objectKey: key, contentType: 'application/x-tar', upstream: false,
    });
    fs.writeFileSync('source-bottle-verification.json', JSON.stringify(results, null, 2));
  } else throw new Error('Expected matrix or publish');
}
module.exports = { record, portable, key, publicURL, queue, matrix, transfer, validFile };
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });
