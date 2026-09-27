const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { recordMetric } = require('../lib/build-metrics.cjs');
const { prefetch: prefetchBottles } = require('./upstream-bottle-cache.cjs');
const { withFreshConfiguration } = require('./source-bottle-config.cjs');

function command(program, args, { inherit = false, cwd, env } = {}) {
  const result = spawnSync(program, args, {
    cwd, env: { ...process.env, ...env }, encoding: 'utf8',
    stdio: inherit ? 'inherit' : ['ignore', 'pipe', 'inherit'], maxBuffer: 32 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${program} ${args.join(' ')} failed (${result.status})`);
  return result.stdout || '';
}

function digest(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function brewSource(mode, args, { run = command, ...options } = {}) {
  return run('brew', ['php-darwin-source', mode, ...args], {
    ...options, env: { ...options.env, PATH: `${__dirname}${path.delimiter}${process.env.PATH}` },
  });
}

function legacyKeyFor(inputs) {
  return `php-darwin-source-v1-${digest(JSON.stringify(inputs))}`;
}

function softwareInputs(inputs) {
  const environment = inputs.environment || {};
  const php = inputs.context?.php;
  // Recipes, build scripts and runner toolchain updates are provenance only.
  // Keep installed dependency versions and the target ABI/platform distinct.
  return {
    formula: inputs.formula, version: inputs.version, source_commit: inputs.source_commit,
    environment: {arch: environment.arch, macos: environment.macos, prefix: environment.prefix},
    dependencies: (inputs.dependencies || []).map(dependency => ({
      name: dependency.name, version: dependency.version,
    })).sort((a, b) => a.name.localeCompare(b.name)),
    ...(inputs.context ? {context: {build: inputs.context.build, ts: inputs.context.ts,
      php: php && {version: php.version, api: php.api, source_commit: php.source_commit}}} : {}),
  };
}

function keyFor(inputs) { return legacyKeyFor(softwareInputs(inputs)); }
function validKey(inputs, key) { return keyFor(inputs) === key || legacyKeyFor(inputs) === key; }

function inspect(mode, formulae, forceSource = false) {
  return JSON.parse(brewSource('info', [mode, JSON.stringify(formulae), String(forceSource)]));
}

function recipeHash(recipe) {
  return digest(command('bash', [path.join(__dirname, '../build/formula-build-inputs.sh'), recipe, 'source']));
}

function buildInputs(formula, environment) {
  const [info] = inspect('inputs', [formula.full_name]);
  const sourceCommit = fs.readFileSync(info.recipe, 'utf8').match(/^\s*url "https:\/\/github\.com\/php\/php-src\/archive\/([a-f0-9]{40})\.tar\.gz/m)?.[1];
  return {
    ...(sourceCommit ? {source_commit: sourceCommit} : {}),
    environment, formula: info.full_name, version: info.version, recipe: recipeHash(info.recipe),
    dependencies: info.dependencies.map(dep => ({ ...dep, recipe: recipeHash(dep.recipe) })),
  };
}

function environment() {
  const buildEnv = {};
  for (const name of ['CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS',
    'MACOSX_DEPLOYMENT_TARGET', 'SDKROOT', 'HOMEBREW_CC', 'HOMEBREW_CXX', 'HOMEBREW_ARCH']) {
    buildEnv[name] = process.env[name] || '';
  }
  return {
    arch: command('uname', ['-m']).trim(),
    macos: command('sw_vers', ['-productVersion']).trim().split('.')[0],
    prefix: command('brew', ['--prefix']).trim(),
    homebrew: command('brew', ['--version']).trim().split('\n')[0].split('.')[0],
    compiler: command('xcrun', ['clang', '--version']).trim(),
    sdk: command('xcrun', ['--sdk', 'macosx', '--show-sdk-version']).trim(),
    buildEnv,
  };
}

function readBottle(directory, key) {
  const metadataPath = path.join(directory, 'metadata.json');
  if (!fs.existsSync(metadataPath)) return null;
  if (!fs.lstatSync(metadataPath).isFile()) throw new Error('Invalid bottle cache metadata');
  const metadata = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
  if (metadata.key !== key || metadata.schema !== 1 ||
    typeof metadata.file !== 'string' || path.basename(metadata.file) !== metadata.file ||
    !/^[A-Za-z0-9@+_.-]+\.bottle(?:\.\d+)?\.tar\.gz$/.test(metadata.file) ||
    !/^[0-9a-f]{64}$/.test(metadata.sha256)) throw new Error('Invalid bottle cache identity');
  const bottle = path.join(directory, metadata.file);
  if (!fs.lstatSync(bottle).isFile() || digest(fs.readFileSync(bottle)) !== metadata.sha256) {
    throw new Error('Cached source bottle checksum mismatch');
  }
  return bottle;
}

async function install({ formula, cache, cacheRoot = '.source-bottle-cache',
  forceSource = false, skipLink = false, context, dependencyRoots, approvedDependencies, preparedTargets = [],
  run = command, query = inspect, inputs = buildInputs, buildEnvironment = environment,
  log = console.log, warn = console.warn, prefetch = prefetchBottles }) {
  if (!/^(?:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/)?[A-Za-z0-9@+_.-]+$/.test(formula)) {
    throw new Error(`Invalid source cache formula: ${formula}`);
  }
  // Match the environment used by build.sh, including its preservation of
  // pinned, preinstalled dependencies. Do not cache or restore the whole Cellar.
  for (const option of ['NO_AUTO_UPDATE', 'NO_AUTOREMOVE', 'NO_ENV_HINTS',
    'NO_INSTALL_CLEANUP', 'NO_INSTALLED_DEPENDENTS_CHECK', 'NO_INSTALL_FROM_API', 'VERBOSE']) {
    process.env[`HOMEBREW_${option}`] = '1';
  }
  process.env.HOMEBREW_VERBOSE_USING_DOTS = '0';
  const requested = dependencyRoots || [formula];
  if (!Array.isArray(requested) || !requested.length || requested.some(name =>
    !/^(?:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/)?[A-Za-z0-9@+_.-]+$/.test(name))) {
    throw new Error('Invalid dependency preparation roots');
  }
  const resolved = query(dependencyRoots ? 'seed' : 'plan', requested, dependencyRoots ? true : forceSource);
  if (!Array.isArray(preparedTargets) || preparedTargets.some(name =>
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/[A-Za-z0-9@+_.-]+$/.test(name))) {
    throw new Error('Invalid prepared package targets');
  }
  // A pack can depend on a member already restored/built in this invocation
  // with the same PHP ABI. It is a package target, not an external dependency.
  // Never let this exemption compile a missing member as an unkeyed dependency.
  for (const item of resolved) {
    if (preparedTargets.includes(item.full_name) && !item.installed) {
      throw new Error(`Previously prepared target is no longer installed: ${item.full_name}`);
    }
  }
  // Dependency preparation never builds PHP or an extension. Packaging tools
  // remain in this union even when requested as roots. Tap-owned build tools
  // are dependencies too; exclude only the actual PHP/extension roots.
  // Homebrew can canonicalize php@CURRENT to php, so use resolved root names.
  const packageRoots = new Set([...requested, ...preparedTargets, ...resolved.filter(item => item.requested).map(item => item.full_name)]
    .filter(name => name.includes('/')));
  const plan = dependencyRoots ? resolved.filter(item => !packageRoots.has(item.full_name)) : resolved;
  const requestedTarget = dependencyRoots ? undefined : plan.at(-1);
  const platform = buildEnvironment();
  if (approvedDependencies) approvedDependencies.validatePlan(plan, platform, { targets: [...packageRoots] });
  log(`Dependency plan for ${dependencyRoots ? 'all configured roots' : formula} (${platform.arch || "unknown arch"}, macOS ${platform.macos || "unknown"}):`);
  for (const item of plan) {
    log(`  ${item.full_name} ${item.version}: ${item.installed ? "current keg" :
      approvedDependencies?.has(item) ? "approved dependency bottle" :
      item.bottled && !(item === plan.at(-1) && forceSource) ? "upstream bottle" : "exact source cache or cold source build"}`);
  }
  const result = { built: 0, restored: 0 };
  if (approvedDependencies) await approvedDependencies.prefetch(plan, { cacheRoot });
  // Homebrew installs the plan one formula at a time. Fetch all missing
  // upstream bottles in one command so its download queue can run concurrently.
  const bottled = plan.filter(item => !item.installed && item.bottled &&
    !(item === requestedTarget && forceSource) && !approvedDependencies?.has(item)).map(item => item.full_name);
  await prefetch(plan.filter(item => bottled.includes(item.full_name) && item.bottle).map(item => item.bottle), { log, warn });
  if (bottled.length > 1) {
    const started = Date.now();
    log(`Prefetching ${bottled.length} upstream bottles`);
    try {
      run('brew', ['fetch', '--formula', ...bottled], { inherit: true });
      recordMetric({ kind: 'prefetch', formula, result: 'complete', count: bottled.length,
        elapsedMs: Date.now() - started });
    } catch (error) {
      // A failed prefetch may still have cached most bottles. Let the normal
      // install path retry the missing one while retaining those downloads.
      warn(`Upstream bottle prefetch incomplete: ${error.message}`);
      recordMetric({ kind: 'prefetch', formula, result: 'incomplete', count: bottled.length,
        elapsedMs: Date.now() - started });
    }
  }
  for (const item of plan) {
    const started = Date.now();
    const metric = values => recordMetric({ kind: 'source', formula: item.full_name,
      elapsedMs: Date.now() - started, ...values });
    const target = item === requestedTarget;
    // The complete dependency plan is installed in topological order here.
    // Do not let each subsequent brew install expand it again: --build-bottle
    // would otherwise demand upgrades to the installed PHP build tool's own
    // runtime libraries, which are unrelated to building an extension.
    // Direct requests may auto-link versioned keg-only formulae in Homebrew.
    // Preserve dependency semantics so legacy Autoconf cannot claim the global
    // commands before an extension installs modern Autoconf.
    const flags = ['--verbose', '--ignore-dependencies', ...(!target ? ['--as-dependency'] : []),
      ...(target && skipLink ? ['--skip-link'] : [])];
    if (item.installed) {
      // A restored PHP cache can select an older keg while the current version
      // remains installed. Point opt at the planned keg without deleting either.
      if (item.select_current) brewSource('select', [item.full_name], { run, inherit: true });
      metric({ result: 'preinstalled' });
      continue;
    }
    if (approvedDependencies?.has(item)) {
      const restored = await approvedDependencies.restore(item, { cache, cacheRoot, run, flags });
      if (restored.source) result.restored++;
      metric({ result: restored.source ? 'approved-source' : 'approved-upstream', key: restored.key });
      continue;
    }
    if (item.bottled && !(target && forceSource)) {
      const incomplete = item.missing_build_files?.length > 0;
      if (incomplete) log(`Restoring incomplete ${item.full_name} bottle; missing: ${item.missing_build_files.join(', ')}`);
      run('brew', incomplete ? ['reinstall', '--formula', '--verbose', '--force-bottle', item.full_name] :
        ['install', '--formula', ...flags, item.full_name], { inherit: true });
      metric({ result: 'upstream-bottle' });
      continue;
    }
    if (item.missing_build_files?.length) {
      throw new Error(`Incomplete installed ${item.full_name}; missing ${item.missing_build_files.join(', ')} and no usable upstream bottle`);
    }
    log(`Resolving source bottle inputs: ${item.full_name} ${item.version}`);
    const build = inputs(item, platform);
    if (target && context) build.context = context;
    const key = keyFor(build);
    const directory = path.join(cacheRoot, key);
    fs.mkdirSync(directory, { recursive: true });
    let bottle;
    let missReason = 'not-cached';
    try {
      bottle = readBottle(directory, key);
      if (!bottle) {
        // Never use a partial/prefix match for compiled packages.
        const restoredKey = await cache.restoreCache([directory], key, [], build);
        if (restoredKey === key) bottle = readBottle(directory, key);
        else if (cache.missReason) missReason = cache.missReason(key, build);
      }
    } catch (error) {
      missReason = 'cache-unavailable-or-invalid';
      warn(`Source cache unavailable for ${item.full_name}: ${error.message}`);
    }
    if (bottle) {
      log(`Restoring source bottle: ${item.full_name} ${item.version}`);
      // Homebrew permits local bottle paths in developer mode. Scope this to
      // installing the exact, checksum-verified bottle we just restored.
      run('brew', ['install', '--formula', ...flags, path.resolve(bottle)], {
        inherit: true, env: { HOMEBREW_DEVELOPER: '1' },
      });
      result.restored++;
      metric({ result: 'restored', key });
      continue;
    }
    const buildMissing = async (waitedMs = 0) => {
      // Another PHP version may have produced this library while this job
      // waited for ownership. Recheck the exact key before compiling anything.
      if (cache.withBuildLock) {
        let cached;
        try {
          const restored = await cache.restoreCache([directory], key, [], build);
          if (restored === key) cached = readBottle(directory, key);
        } catch (error) {
          missReason = 'cache-unavailable-or-invalid';
          warn(`Source cache unavailable while owning ${item.full_name}: ${error.message}`);
        }
        if (cached) {
          run('brew', ['install', '--formula', ...flags, path.resolve(cached)], {
            inherit: true, env: { HOMEBREW_DEVELOPER: '1' },
          });
          result.restored++;
          log(`Restored source bottle after coordination: ${item.full_name} ${item.version}`);
          metric({ result: 'restored-after-wait', key, waitedMs });
          return;
        }
      }
      fs.rmSync(directory, { recursive: true, force: true });
      fs.mkdirSync(directory, { recursive: true });
      log(`Building source bottle: ${item.full_name} ${item.version} (${missReason}; ${key})`);
      metric({ result: 'build-started', key, missReason });
      const compileStarted = Date.now();
      let compileMs;
      let bottleStarted;
      withFreshConfiguration(platform.prefix, item.configuration_files, () => {
        brewSource('install', ['--formula', '--build-bottle', ...flags, item.full_name], { run, inherit: true });
        compileMs = Date.now() - compileStarted;
        bottleStarted = Date.now();
        run('brew', ['bottle', '--json', '--no-rebuild', item.full_name], {
          inherit: true, cwd: path.resolve(directory),
        });
      });
      const files = fs.readdirSync(directory).filter(file => file.endsWith('.tar.gz'));
      if (files.length !== 1) throw new Error(`Expected one bottle for ${item.full_name}`);
      const file = files[0];
      const sha256 = digest(fs.readFileSync(path.join(directory, file)));
      fs.writeFileSync(path.join(directory, 'metadata.json'), JSON.stringify({ schema: 1, key, file, sha256, inputs: build }));
      readBottle(directory, key);
      // --build-bottle skips post_install. Run it after bottling so first builds
      // and restored bottles both recreate PHP/PEAR and dependency configuration.
      if (item.post_install) run('brew', ['postinstall', '--verbose', item.full_name], { inherit: true });
      const bottleMs = Date.now() - bottleStarted;
      result.built++;
      const uploadStarted = Date.now();
      let saved = true;
      let saveError;
      try {
        await cache.saveCache([directory], key);
      } catch (error) {
        saved = false;
        saveError = error.message;
        warn(`Could not save source bottle for ${item.full_name}: ${error.message}`);
      }
      metric({ result: 'built', key, missReason, waitedMs, compileMs, bottleMs,
        uploadMs: Date.now() - uploadStarted, saved, ...(saveError ? { saveError } : {}) });
    };
    if (cache.withBuildLock) {
      log(`Acquiring source build ownership: ${item.full_name} (${key})`);
      await cache.withBuildLock(key, buildMissing);
    }
    else await buildMissing();
  }
  log(`Source bottles: ${result.restored} restored, ${result.built} built`);
  return result;
}

function extensionInputs(abstract, phpPrefix, build, ts, run = command) {
  const include = run(path.join(phpPrefix, 'bin/php-config'), ['--include-dir']).trim();
  const api = {};
  for (const [header, name] of [['main/php.h', 'PHP_API_VERSION'],
    ['Zend/zend_modules.h', 'ZEND_MODULE_API_NO'], ['Zend/zend_extensions.h', 'ZEND_EXTENSION_API_NO']]) {
    const match = fs.readFileSync(path.join(include, header), 'utf8').match(new RegExp(`^#define\\s+${name}\\s+(\\d+)`, 'm'));
    if (!match) throw new Error(`Missing ${name} in installed PHP headers`);
    api[name] = match[1];
  }
  return {
    build, ts, abstract: digest(fs.readFileSync(abstract)),
    php: {
      version: run(path.join(phpPrefix, 'bin/php-config'), ['--version']).trim(),
      api,
      configure: run(path.join(phpPrefix, 'bin/php-config'), ['--configure-options']).trim(),
      extensionDirectory: run(path.join(phpPrefix, 'bin/php-config'), ['--extension-dir']).trim(),
    },
  };
}

module.exports = { command, brewSource, keyFor, legacyKeyFor, validKey, softwareInputs, readBottle, install, extensionInputs, environment, recipeHash };
