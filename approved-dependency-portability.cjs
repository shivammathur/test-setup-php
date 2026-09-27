const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createHash} = require('node:crypto');
const base = path.join(__dirname, 'darwin');
const {readLock, validatePlatform, ApprovedDependencies} = require(path.join(base, 'scripts/cache/approved-dependencies.cjs'));
const {install, command, environment} = require(path.join(base, 'scripts/cache/source-bottle-cache.cjs'));
const {ReleaseCache} = require(path.join(base, 'scripts/cache/source-bottle-releases.cjs'));
async function main() {
  assert.equal(process.platform, 'darwin');
  assert.equal(process.env.GITHUB_ACTIONS, 'true');
  assert.equal(process.env.RUNNER_ENVIRONMENT, 'github-hosted');
  const file = path.join(base, 'dependencies-x86_64.json');
  const lock = readLock(file);
  const approvedPlatform = validatePlatform(lock.platforms.x86_64, 'x86_64');
  const proof = JSON.parse(fs.readFileSync(path.join(base, 'dependency-verification-x86_64.json')));
  const sha256 = createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  assert.equal(proof.schema, 1);
  assert.equal(proof.arch, 'x86_64');
  assert.equal(proof.core_commit, lock.core_commit);
  assert.equal(proof.sha256, sha256);
  assert.equal(proof.dependencies, Object.keys(approvedPlatform.packages).length);
  assert.equal(proof.cold_source_builds, 0);
  assert.equal(proof.hot_source_builds, 0);
  assert(approvedPlatform.packages.gcc?.source, 'Expected the approved source-built GCC bottle');
  if (process.argv[2] === 'prepare') {
    fs.appendFileSync(process.env.GITHUB_ENV, `HOMEBREW_CORE_COMMIT=${lock.core_commit}\nPHP_DARWIN_METRICS=${path.join(base, 'hosted-intel-approved-dependency-metrics.jsonl')}\n`);
    return;
  }
  assert.equal(process.argv[2], 'verify');
  const consumer = environment();
  assert.equal(consumer.arch, 'x86_64');
  assert.equal(consumer.macos, '15');
  const sourceBuilds = [];
  const run = (program, args, options) => {
    if (args.includes('--build-bottle')) {
      sourceBuilds.push(args);
      throw new Error('Portability verification must never compile a dependency');
    }
    return command(program, args, options);
  };
  const options = {formula: 'gcc', approvedDependencies: new ApprovedDependencies(lock),
    cache: new ReleaseCache({repository: 'shivammathur/php-darwin'}),
    cacheRoot: path.join(base, '.hosted-approved-dependencies'), run};
  const cold = await install(options);
  assert.equal(cold.built, 0);
  assert(cold.restored >= 1, 'Cold run must restore GCC from the approved source bottle');
  command('brew', ['linkage', '--test', 'gcc'], {inherit: true});
  const gcc = approvedPlatform.packages.gcc;
  const major = gcc.version.split('.')[0];
  const prefix = command('brew', ['--prefix', 'gcc']).trim();
  const directory = fs.mkdtempSync(path.join(process.env.RUNNER_TEMP, 'approved-gcc-portability-'));
  try {
    const source = path.join(directory, 'smoke.cc');
    fs.writeFileSync(source, '#include <iostream>\nint main() { std::cout << 42; }\n');
    for (const flags of [[], ['-O2', '-flto']]) {
      const binary = path.join(directory, flags.length ? 'smoke-lto' : 'smoke');
      command(path.join(prefix, 'bin', `g++-${major}`), [...flags, source, '-o', binary], {inherit: true});
      assert.equal(command(binary, []).trim(), '42');
    }
  } finally {fs.rmSync(directory, {recursive: true, force: true});}
  const hot = await install(options);
  assert.deepEqual(hot, {built: 0, restored: 0});
  assert.deepEqual(sourceBuilds, []);
  const result = {schema: 1, catalog_sha256: sha256, core_commit: lock.core_commit,
    producer: gcc.source.inputs.environment, consumer, gcc_version: gcc.version,
    gcc_key: gcc.source.key, gcc_bottle_sha256: gcc.source.sha256,
    cold, hot, linkage_passed: true, compiler_smoke_passed: true, lto_smoke_passed: true};
  fs.writeFileSync(path.join(base, 'hosted-intel-approved-dependency-proof.json'), JSON.stringify(result, null, 2)+'\n');
  console.log(JSON.stringify(result, null, 2));
}
main().catch(error => {console.error(error); process.exitCode = 1;});
