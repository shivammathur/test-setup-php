const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { install, environment, brewSource, command, readBottle } = require('./source-bottle-cache.cjs');
const { ReleaseCache } = require('./source-bottle-releases.cjs');
const { readLock, validatePlatform, ApprovedDependencies } = require('./approved-dependencies.cjs');
const { portable } = require('./upstream-bottle-cache.cjs');
const root = path.resolve(__dirname, '../..');
const config = name => JSON.parse(fs.readFileSync(path.join(root, 'conf', name), 'utf8'));
const records = file => fs.readFileSync(path.join(root, 'conf', file), 'utf8').split('\n')
  .map(line => line.trim()).filter(line => line && !line.startsWith('#')).map(line => line.split(/\s+/));

function roots() {
  const packages = config('package.json'), packs = config('extension-packs.json');
  const result = new Set(['jq', 'zstd']);
  for (const [, php] of records('versions')) {
    for (const [build, ts] of records('variants')) {
      const suffix = `${build === 'debug' ? '-debug' : ''}${ts === 'zts' ? '-zts' : ''}`;
      result.add(`${packages.tap}/php@${php}${suffix}`);
    }
    const extensions = records(`cached-extensions/${php}`).map(([name]) => name);
    if (packs.versions.includes(php)) extensions.push(...Object.values(packs.packs).flat());
    for (const name of extensions) result.add(`${packages.extension_tap}/${name}@${php}`);
  }
  return [...result].sort();
}

function requireRunner() {
  if (process.platform !== 'darwin' || process.env.GITHUB_ACTIONS !== 'true') {
    throw new Error('Dependency preparation and cleanup require a macOS Actions runner');
  }
}

function clean() {
  requireRunner();
  const names = command('brew', ['list', '--formula']).trim().split('\n').filter(Boolean);
  if (names.some(name => !/^[A-Za-z0-9@+_.-]+$/.test(name))) throw new Error('Invalid installed formula name');
  const pinned = command('brew', ['list', '--pinned']).trim().split('\n').filter(Boolean);
  if (pinned.length) command('brew', ['unpin', ...pinned], { inherit: true });
  if (names.length) command('brew', ['uninstall', '--formula', '--force', '--ignore-dependencies', ...names], { inherit: true });
}

async function prepare() {
  requireRunner();
  const core = process.env.HOMEBREW_CORE_COMMIT;
  if (!/^[a-f0-9]{40}$/.test(core || '')) throw new Error('Missing dependency snapshot commit');
  const platform = environment();
  const expected = config('platforms.json')[platform.arch];
  if (!expected || platform.prefix !== expected.brew_prefix || Number(platform.macos) !== expected.minimum_macos) {
    throw new Error('Prepare dependencies on their configured baseline macOS runner');
  }
  const requested = roots();
  const cache = new ReleaseCache();
  const cacheRoot = '.source-bottle-cache';
  await install({ formula: 'jq', dependencyRoots: requested, cache, cacheRoot });
  const packageRoots = new Set(requested.filter(name => name.includes('/')));
  const plan = JSON.parse(brewSource('info', ['seed', JSON.stringify(requested), 'true']))
    .filter(item => !packageRoots.has(item.full_name) && !(item.requested && item.full_name.includes('/')));
  const cached = fs.existsSync(cacheRoot) ? fs.readdirSync(cacheRoot).flatMap(name => {
    const metadata = path.join(cacheRoot, name, 'metadata.json');
    return fs.existsSync(metadata) ? [JSON.parse(fs.readFileSync(metadata))] : [];
  }) : [];
  const packages = {};
  for (const item of plan) {
    if (!item.installed) throw new Error(`Prepared dependency is not installed: ${item.full_name}`);
    if (item.bottle) {
      packages[item.full_name] = { version: item.version, bottle: portable(item.bottle) };
      continue;
    }
    const matching = cached.filter(record => record.inputs.formula === item.full_name && record.inputs.version === item.version);
    if (matching.length !== 1) throw new Error(`Expected one prepared source bottle for ${item.full_name}; found ${matching.length}`);
    const { key, inputs } = matching[0];
    const directory = path.join(cacheRoot, 'verified', key);
    fs.mkdirSync(directory, { recursive: true });
    if (await cache.restoreCache([directory], key, [], inputs) !== key) {
      throw new Error(`Dependency was not saved for future cache jobs: ${item.full_name}`);
    }
    readBottle(directory, key);
    const metadata = JSON.parse(fs.readFileSync(path.join(directory, 'metadata.json')));
    packages[item.full_name] = { version: item.version, source: { key, inputs, sha256: metadata.sha256 } };
  }
  const candidate = { schema: 1, core_commit: core, platforms: {
    [platform.arch]: { macos: Number(platform.macos), prefix: platform.prefix, packages },
  } };
  validatePlatform(candidate.platforms[platform.arch], platform.arch);
  fs.writeFileSync(`dependencies-${platform.arch}.json`, JSON.stringify(candidate, null, 2) + '\n');
  fs.writeFileSync('dependency-roots.json', JSON.stringify(requested, null, 2) + '\n');
  fs.writeFileSync('dependency-plan.json', JSON.stringify(plan, null, 2) + '\n');
  console.log(`Prepared ${Object.keys(packages).length} approved dependencies for ${platform.arch}`);
}

async function verify() {
  requireRunner();
  const platform = environment();
  const file = `dependencies-${platform.arch}.json`;
  const lock = readLock(file), approved = new ApprovedDependencies(lock);
  const requested = roots();
  // A genuinely empty prefix proves every dependency is obtainable without
  // source compilation, including tools that were preinstalled on the image.
  clean();
  const result = await install({ formula: 'jq', dependencyRoots: requested, approvedDependencies: approved,
    cache: new ReleaseCache(), cacheRoot: '.approved-dependency-verification' });
  if (result.built !== 0) throw new Error('Approved dependency verification compiled a package');
  const names = Object.keys(lock.platforms[platform.arch].packages);
  command('brew', ['linkage', '--test', ...names], { inherit: true });
  for (const [program, args] of [['jq', ['--version']], ['zstd', ['--version']]]) {
    command(program, args, { inherit: true });
  }
  for (const name of names.filter(name => /^gcc(?:@\d+)?$/.test(name))) {
    const major = lock.platforms[platform.arch].packages[name].version.split('.')[0];
    const prefix = command('brew', ['--prefix', name]).trim();
    const directory = fs.mkdtempSync(path.join(process.env.RUNNER_TEMP, 'approved-gcc-'));
    try {
      const source = path.join(directory, 'smoke.cc'), binary = path.join(directory, 'smoke');
      fs.writeFileSync(source, '#include <iostream>\nint main() { std::cout << 42; }\n');
      command(path.join(prefix, 'bin', `g++-${major}`), [source, '-o', binary], { inherit: true });
      if (command(binary, []).trim() !== '42') throw new Error(`Approved ${name} failed its compiler smoke test`);
    } finally { fs.rmSync(directory, { recursive: true, force: true }); }
  }
  const hot = await install({ formula: 'jq', dependencyRoots: requested, approvedDependencies: approved,
    cache: new ReleaseCache(), cacheRoot: '.approved-dependency-verification' });
  if (hot.built !== 0 || hot.restored !== 0) throw new Error('Warm approved dependencies were not reused');
  const sha256 = createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  fs.writeFileSync(`dependency-verification-${platform.arch}.json`, JSON.stringify({
    schema: 1, arch: platform.arch, core_commit: lock.core_commit, sha256,
    dependencies: names.length, cold_source_builds: result.built, hot_source_builds: hot.built,
  }, null, 2) + '\n');
}

function merge(directory, output) {
  const merged = { schema: 1, core_commit: '', platforms: {} };
  for (const arch of ['arm64', 'x86_64']) {
    const file = path.join(directory, `dependencies-${arch}.json`);
    const lock = readLock(file);
    const verification = JSON.parse(fs.readFileSync(path.join(directory, `dependency-verification-${arch}.json`)));
    if (verification.schema !== 1 || verification.arch !== arch || verification.core_commit !== lock.core_commit ||
        verification.dependencies !== Object.keys(lock.platforms[arch]?.packages || {}).length ||
        verification.cold_source_builds !== 0 || verification.hot_source_builds !== 0 ||
        verification.sha256 !== createHash('sha256').update(fs.readFileSync(file)).digest('hex')) {
      throw new Error(`Missing or mismatched native dependency verification: ${arch}`);
    }
    if (merged.core_commit && merged.core_commit !== lock.core_commit) throw new Error('Dependency snapshots differ across architectures');
    merged.core_commit = lock.core_commit;
    merged.platforms[arch] = validatePlatform(lock.platforms[arch], arch);
  }
  fs.writeFileSync(output, JSON.stringify(merged, null, 2) + '\n');
}

async function promote(file) {
  if (process.env.GITHUB_ACTIONS !== 'true' || process.env.GITHUB_REPOSITORY !== 'shivammathur/php-darwin' ||
      process.env.GITHUB_REF_NAME !== 'main') throw new Error('Dependency promotion requires the php-darwin main workflow');
  const lock = readLock(file);
  for (const arch of ['arm64', 'x86_64']) validatePlatform(lock.platforms[arch], arch);
  const cache = new ReleaseCache();
  const current = await cache.api('contents/conf/dependencies.json?ref=main');
  const expected = command('git', ['rev-parse', 'HEAD:conf/dependencies.json']).trim();
  if (current.sha !== expected) throw new Error('The approved dependency snapshot changed while this update ran');
  const content = fs.readFileSync(file);
  if (Buffer.from(current.content, 'base64').equals(content)) {
    console.log('Approved dependencies are already current');
    return;
  }
  await cache.api('contents/conf/dependencies.json', { method: 'PUT', body: {
    message: 'Update approved dependency bottles', branch: 'main', sha: current.sha,
    content: content.toString('base64'),
  } });
}

module.exports = { roots, merge };
if (require.main === module) {
  (async () => {
    const [mode, directory, output] = process.argv.slice(2);
    if (mode === 'clean') clean();
    else if (mode === 'prepare') await prepare();
    else if (mode === 'verify') await verify();
    else if (mode === 'merge') merge(directory, output);
    else if (mode === 'promote') await promote(directory);
    else throw new Error('Expected clean, prepare, verify, merge, or promote');
  })().catch(error => { console.error(error); process.exitCode = 1; });
}
