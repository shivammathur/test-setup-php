const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { install, command, environment } = require('../../cache/source-bottle-cache.cjs');
const { ApprovedDependencies } = require('../../cache/approved-dependencies.cjs');
const { ReleaseCache } = require('../../cache/source-bottle-releases.cjs');

async function main() {
  if (process.platform !== 'darwin' || process.env.GITHUB_ACTIONS !== 'true') throw new Error('Native Actions runner required');
  const tap = 'php-darwin/source-cache-test', app = `${tap}/php-darwin-cache-app`;
  const library = `${tap}/php-darwin-cache-lib`, tool = `${tap}/php-darwin-cache-tool@1`;
  const platform = environment(), packages = {};
  for (const key of fs.readdirSync('.source-bottle-cache')) {
    const metadata = JSON.parse(fs.readFileSync(path.join('.source-bottle-cache', key, 'metadata.json')));
    if (![library, tool].includes(metadata.inputs.formula)) continue;
    packages[metadata.inputs.formula] = {version: metadata.inputs.version, source: {
      key, inputs: metadata.inputs, sha256: metadata.sha256,
    }};
  }
  assert.equal(Object.keys(packages).length, 2);
  const approved = new ApprovedDependencies({platforms: {
    [platform.arch]: {prefix: platform.prefix, macos: Number(platform.macos), packages},
  }});
  const cache = new ReleaseCache({tag: process.env.CACHE_RELEASE});
  const events = [];
  const run = (program, args, options) => {
    if (args.includes('--build-bottle')) events.push(args.at(-1));
    return command(program, args, options);
  };
  const options = {formula: app, cache, approvedDependencies: approved, run,
    // The source-cache key must be irrelevant to consuming an already approved
    // dependency, even when the next image has a different compiler/SDK.
    buildEnvironment: () => ({...platform, sdk: `${platform.sdk}-native-regression`})};
  command('brew', ['uninstall', '--force', '--ignore-dependencies', app, library, tool], {inherit: true});
  fs.rmSync('.source-bottle-cache', {recursive: true});
  assert.deepEqual(await install(options), {built: 1, restored: 2});
  assert.deepEqual(events, [app]);
  assert.equal(command(path.join(platform.prefix, 'bin/php-darwin-cache-app'), []).trim(), '42');
  assert.deepEqual(await install(options), {built: 0, restored: 0});

  const formula = path.join(command('brew', ['--repository', tap]).trim(), 'Formula/php-darwin-cache-tool@1.rb');
  const original = fs.readFileSync(formula, 'utf8');
  command('brew', ['uninstall', '--force', '--ignore-dependencies', app], {inherit: true});
  try {
    fs.writeFileSync(formula, original.replace('version "1.0.0"', 'version "1.0.1"'));
    events.length = 0;
    await assert.rejects(install(options), /not in the approved snapshot/);
    assert.deepEqual(events, []);
  } finally { fs.writeFileSync(formula, original); }
  assert.deepEqual(await install(options), {built: 0, restored: 1});
  console.log('Native approved dependencies survive toolchain-key changes; unapproved tool patches never compile or install');
}
main().catch(error => {console.error(error); process.exitCode = 1;});
