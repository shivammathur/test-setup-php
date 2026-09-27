const {test} = require('node:test');
const assert = require('node:assert/strict');
const {validate} = require('../../release/php-recovery.cjs');

function fixture() {
  const source = {status: 'completed', conclusion: 'failure', head_branch: 'main', head_sha: 'a'.repeat(40),
    head_repository: {full_name: 'shivammathur/php-darwin'}, path: '.github/workflows/cache-stable.yml'};
  const plan = {schema: 1, php_version: '8.5', revision: source.head_sha,
    builds: ['debug', 'release'].flatMap(build => ['nts', 'zts'].map(ts => ({arch: 'arm64', build, ts}))),
    tests: [{arch: 'arm64', runner: 'macos-14'}, {arch: 'arm64', runner: 'macos-15'}]};
  const jobs = [...plan.builds.map(({arch, build, ts}) => `${arch} / Build PHP 8.5 ${build}/${ts} package on ${arch}`),
    ...plan.tests.map(({arch, runner}) => `${arch} / Test PHP 8.5 packages on ${runner}`)]
    .map(name => ({name: 'cache / ' + name, status: 'completed', conclusion: 'success'}));
  jobs.push({name: 'cache / publish', status: 'completed', conclusion: 'failure'});
  const artifacts = plan.builds.map(({arch, build, ts}, id) => ({id: id + 1,
    name: `php-8.5-${arch}-${build}-${ts}-${'b'.repeat(64)}`, digest: 'sha256:' + 'c'.repeat(64)}));
  const run = () => validate(source, jobs, artifacts, plan, '8.5');
  return {source, plan, jobs, artifacts, run};
}

test('recovery accepts tested variants after publication failure and binds exact artifacts', () => {
  const f = fixture(); assert.deepEqual(f.run(), f.artifacts);
  f.jobs.push({name: 'cache / bottle mirror', conclusion: 'failure'});
  assert.deepEqual(f.run(), f.artifacts);
});
test('recovery rejects wrong workflows, versions, branches, and source repositories', () => {
  for (const field of ['head_branch', 'path', 'head_sha']) {
    const f = fixture(); f.source[field] = 'wrong'; assert.throws(f.run);
  }
  const f = fixture(); f.source.head_repository.full_name = 'other/php-darwin'; assert.throws(f.run);
  f.source.head_repository.full_name = 'shivammathur/php-darwin'; f.plan.php_version = '8.4'; assert.throws(f.run);
});
test('every planned build and compatibility runner must pass', () => {
  for (let i = 0; i < 6; i++) {
    const f = fixture(); f.jobs[i].conclusion = 'failure'; assert.throws(f.run);
    f.jobs.splice(i, 1); assert.throws(f.run);
  }
});
test('expired, duplicate, missing, or unauthenticated archives cannot be published', () => {
  for (const mutate of [f => f.artifacts.pop(), f => f.artifacts.push({...f.artifacts[0], id: 99}),
    f => {f.artifacts[0].expired = true;}, f => {delete f.artifacts[0].digest;},
    f => {f.plan.builds.pop();}]) {
    const f = fixture(); mutate(f); assert.throws(f.run);
  }
});
