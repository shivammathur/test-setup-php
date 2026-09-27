const fs = require('node:fs');
const path = require('node:path');
const upstream = require('./upstream-bottle-cache.cjs');
const { retryPolicy, httpError } = require('../release/extension-transfers.cjs');

const defaultFile = path.resolve(__dirname, '../../conf/dependencies.json');
const formulaPattern = /^(?:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/)?[A-Za-z0-9@+_.-]+$/;
const hex = /^[a-f0-9]{64}$/;

function readLock(file = defaultFile) {
  const lock = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (lock.schema !== 1 || !/^[a-f0-9]{40}$/.test(lock.core_commit || '')) {
    throw new Error('Invalid approved dependency snapshot');
  }
  return lock;
}

function validatePlatform(platform, arch) {
  if (!['arm64', 'x86_64'].includes(arch) || !platform ||
      platform.prefix !== (arch === 'arm64' ? '/opt/homebrew' : '/usr/local') ||
      !Number.isInteger(platform.macos) || platform.macos < 11 ||
      !platform.packages || !Object.keys(platform.packages).length) {
    throw new Error(`Dependency bottles have not been prepared for ${arch}`);
  }
  const { validKey } = require('./source-bottle-cache.cjs');
  for (const [formula, entry] of Object.entries(platform.packages)) {
    if (!formulaPattern.test(formula) || !/^[A-Za-z0-9+_.-]+$/.test(entry.version || '') ||
        Boolean(entry.bottle) === Boolean(entry.source)) throw new Error(`Invalid approved dependency: ${formula}`);
    if (entry.bottle) {
      upstream.validate(entry.bottle);
      if (entry.bottle.formula !== formula || entry.bottle.version !== entry.version) {
        throw new Error(`Approved bottle identity differs: ${formula}`);
      }
    } else {
      const { key, inputs, sha256 } = entry.source;
      const env = inputs?.environment;
      if (!hex.test(sha256 || '') || !inputs || !validKey(inputs, key) ||
          inputs.formula !== formula || inputs.version !== entry.version ||
          env?.arch !== arch || String(env.macos) !== String(platform.macos) || env.prefix !== platform.prefix) {
        throw new Error(`Approved source bottle identity differs: ${formula}`);
      }
    }
  }
  return platform;
}

function protectedSourceKeys(file = defaultFile) {
  if (!fs.existsSync(file)) return new Set();
  const lock = readLock(file);
  const {keyFor, legacyKeyFor} = require('./source-bottle-cache.cjs');
  return new Set(Object.values(lock.platforms || {}).flatMap(platform =>
    Object.values(platform.packages || {}).flatMap(entry => {
      if (!entry.source) return [];
      const {key, inputs} = entry.source;
      // A legacy restore changes only the local key, preserving its original
      // inputs and remote asset. Protect both identities until promotion.
      return inputs ? [key, keyFor(inputs), legacyKeyFor(inputs)] : [key];
    })));
}

class ApprovedDependencies {
  constructor(lock, { download = upstream.transfer, retry = retryPolicy({ attempts: 3, budget: 8, delay: 1000 }) } = {}) {
    this.lock = lock;
    this.download = download;
    this.retry = retry;
  }

  validatePlan(plan, environment, { targets = [] } = {}) {
    this.platform = validatePlatform(this.lock.platforms?.[environment.arch], environment.arch);
    this.targets = new Set(targets.filter(name => name.includes('/')));
    if (environment.prefix !== this.platform.prefix || Number(environment.macos) < this.platform.macos) {
      throw new Error('Runner cannot use the approved dependency platform');
    }
    for (const item of plan) {
      if (!this.has(item)) continue;
      const entry = this.platform.packages[item.full_name];
      if (!entry || entry.version !== item.version) {
        throw new Error(`Dependency ${item.full_name} ${item.version} is not in the approved snapshot; run update-dependencies.yml before changing dependencies`);
      }
    }
  }

  has(item) {
    // Requested PHP/extensions remain independently buildable. An installed
    // PHP runtime used to build extensions comes from its published archive.
    // All other dependencies, including tap-owned build tools, are approved.
    return Boolean(this.platform?.packages[item.full_name]) ||
      (!this.targets?.has(item.full_name) && !/^shivammathur\/php\/php(?:@\d+\.\d+)?(?:-debug)?(?:-zts)?$/.test(item.full_name));
  }

  async prefetch(plan, { cacheRoot }) {
    const records = plan.filter(item => !item.installed && this.has(item))
      .map(item => this.platform.packages[item.full_name]?.bottle).filter(Boolean)
      .map(record => ({...record, cached_download: path.resolve(this.upstreamFile(record, cacheRoot))}));
    await upstream.prefetch(records, { download: this.download });
  }

  upstreamFile(record, cacheRoot) {
    return path.join(cacheRoot, 'approved', record.sha256,
      `${record.formula.split('/').at(-1)}--${record.version}.${record.tag}.bottle.tar.gz`);
  }

  async restore(item, { cache, cacheRoot, run, flags }) {
    const entry = this.platform.packages[item.full_name];
    let bottle;
    if (entry.source) {
      const { readBottle } = require('./source-bottle-cache.cjs');
      const { key, inputs, sha256 } = entry.source;
      const directory = path.join(cacheRoot, key);
      fs.mkdirSync(directory, { recursive: true });
      try {
        bottle = readBottle(directory, key);
        if (bottle && JSON.parse(fs.readFileSync(path.join(directory, 'metadata.json'))).sha256 !== sha256) bottle = undefined;
      } catch { bottle = undefined; }
      if (!bottle) {
        const restored = await cache.restoreCache([directory], key, [], inputs);
        if (restored !== key) throw new Error(`Approved dependency bottle is unavailable: ${item.full_name}; dependency compilation is restricted to update-dependencies.yml`);
        bottle = readBottle(directory, key);
      }
      const metadata = JSON.parse(fs.readFileSync(path.join(directory, 'metadata.json')));
      if (!bottle || metadata.sha256 !== sha256) throw new Error(`Approved dependency checksum differs: ${item.full_name}`);
    } else {
      const record = entry.bottle;
      const directory = path.join(cacheRoot, 'approved', record.sha256);
      fs.mkdirSync(directory, { recursive: true });
      bottle = this.upstreamFile(record, cacheRoot);
      if (!await upstream.validFile(bottle, record.sha256)) {
        await this.retry(`Approved bottle ${item.full_name}`, async () => {
          let status;
          try { status = await this.download(upstream.publicURL(record), bottle); } catch { status = 0; }
          if (status !== 200 || !await upstream.validFile(bottle, record.sha256)) {
            status = await this.download(record.url, bottle, { upstream: true });
            if (process.env.PHP_DARWIN_BOTTLE_MISSES) {
              fs.appendFileSync(process.env.PHP_DARWIN_BOTTLE_MISSES, JSON.stringify(record) + '\n');
            }
          }
          if (status !== 200) throw httpError(status, `Approved bottle download failed: ${item.full_name}`);
          if (!await upstream.validFile(bottle, record.sha256)) throw new Error(`Approved bottle checksum differs: ${item.full_name}`);
        });
      }
    }
    const repair = item.missing_build_files?.length > 0;
    if (!repair && item.installed_versions?.length) {
      // Homebrew refuses to install an older approved bottle while a newer keg
      // is installed. This action runs only on disposable build runners.
      run('brew', ['uninstall', '--formula', '--force', '--ignore-dependencies', item.full_name], { inherit: true });
    }
    run('brew', repair ? ['reinstall', '--formula', '--verbose', '--force-bottle', path.resolve(bottle)] :
      ['install', '--formula', ...flags, '--force-bottle', path.resolve(bottle)],
    { inherit: true, env: { HOMEBREW_DEVELOPER: '1' } });
    console.log(`Restored approved dependency: ${item.full_name} ${entry.version}`);
    return { source: Boolean(entry.source), key: entry.source?.key || entry.bottle.sha256 };
  }
}

module.exports = { readLock, validatePlatform, protectedSourceKeys, ApprovedDependencies, defaultFile };
if (require.main === module) {
  try {
    const lock = readLock(process.argv[3]);
    if (process.argv[2] === 'core') console.log(lock.core_commit);
    else if (process.argv[2] === 'check') {
      for (const arch of ['arm64', 'x86_64']) validatePlatform(lock.platforms?.[arch], arch);
    } else throw new Error('Expected core or check');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
