const fs = require('node:fs');
const path = require('node:path');
const { install, command, extensionInputs } = require('../../../scripts/cache/source-bottle-cache.cjs');
const { ReleaseCache } = require('../../../scripts/cache/source-bottle-releases.cjs');
const { ApprovedDependencies, readLock } = require('../../../scripts/cache/approved-dependencies.cjs');

async function main() {
  if (process.platform !== 'darwin' || process.env.GITHUB_ACTIONS !== 'true') {
    throw new Error('Source bottle installation requires a macOS Actions runner');
  }
  const cache = new ReleaseCache({ tag: process.env.INPUT_RELEASE || 'cache' });
  const mode = process.env['INPUT_DEPENDENCY-MODE'] || 'approved';
  if (!['approved', 'update'].includes(mode)) throw new Error('Invalid dependency mode');
  const lock = mode === 'approved' ? readLock(process.env.PHP_DARWIN_DEPENDENCY_LOCK) : undefined;
  if (lock && process.env.HOMEBREW_CORE_COMMIT && process.env.HOMEBREW_CORE_COMMIT !== lock.core_commit) {
    throw new Error('Homebrew core differs from the approved dependency snapshot');
  }
  const approvedDependencies = lock ? new ApprovedDependencies(lock) : undefined;
  if (process.env.INPUT_STAGE === 'tools') {
    const result = { built: 0, restored: 0 };
    for (const formula of ['jq', 'zstd']) {
      const installed = await install({ formula, cache, approvedDependencies });
      result.built += installed.built;
      result.restored += installed.restored;
    }
    writeOutputs(result);
    return;
  }
  if (process.argv[2] === 'install-extensions') {
    const [abstract, phpPrefix, ...formulae] = process.argv.slice(3);
    const context = extensionInputs(abstract, phpPrefix, process.env.BUILD, process.env.TS);
    if (process.env.PHP_DARWIN_PHP_SRC_COMMIT) {
      if (!/^[0-9a-f]{40}$/.test(process.env.PHP_DARWIN_PHP_SRC_COMMIT)) throw new Error('Invalid PHP source commit');
      context.php.source_commit = process.env.PHP_DARWIN_PHP_SRC_COMMIT;
    }
    const result = { built: 0, restored: 0 };
    const preparedTargets = [];
    for (const formula of formulae) {
      const installed = await install({ formula, cache, context, skipLink: true, approvedDependencies, preparedTargets,
        forceSource: !!context.php.source_commit || process.env.BUILD !== 'release' || process.env.TS !== 'nts' || process.env['INPUT_FORCE-SOURCE'] === 'true' });
      preparedTargets.push(formula);
      result.built += installed.built;
      result.restored += installed.restored;
    }
    writeOutputs(result);
    return;
  }
  if (process.env.INPUT_STAGE === 'extensions') {
    command('bash', ['scripts/build/build-extensions.sh'], { inherit: true,
      env: { PHP_DARWIN_SOURCE_CACHE_NODE: process.execPath,
        PHP_DARWIN_SOURCE_CACHE_ACTION: path.join(__dirname, 'main.cjs') } });
    return;
  }
  if (process.env.INPUT_STAGE && process.env.INPUT_STAGE !== 'php') throw new Error('Invalid source cache stage');
  const override = process.env.INPUT_FORMULA;
  const formula = override || command('bash', ['-c',
    '. scripts/lib/lib.sh; requested=$(php_darwin_requested_formula "$PHP_VERSION" "$BUILD" "$TS") || exit 1; printf "%s/%s" "$(php_darwin_package_config tap)" "$requested"'
  ]).trim();
  const result = await install({ formula, cache, approvedDependencies, forceSource: process.env['INPUT_FORCE-SOURCE'] === 'true' });
  if (!override) command('bash', ['scripts/build/build.sh', 'finalize'], { inherit: true });
  writeOutputs(result);
}

function writeOutputs(result) {
  for (const [name, value] of Object.entries(result)) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`);
  }
}

if (process.argv[2] === '--worker') {
  process.argv.splice(2, 1);
  main().catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
} else {
  require('../../../scripts/build/supervise-build.cjs').supervise(process.execPath,
    [__filename, '--worker', ...process.argv.slice(2)]);
}
