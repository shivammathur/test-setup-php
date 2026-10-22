const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const expectedReal = require('./expected.cjs');
const layouts = require('./layouts.cjs');
const fixture = '.github/tests/phpunit-matchers/OutcomesTest.php';
const installed = path.join(process.env.RUNNER_TOOL_CACHE || '.', 'phpunit.json');
const [mode, group, majorArg, order] = process.argv.slice(2);
const major = Number(majorArg);
const register = () => console.log(`::add-matcher::${installed}`);
const remove = () => console.log(`::remove-matcher::${installed}`);
fs.mkdirSync('evidence', {recursive: true});
const save = (name, value) => fs.writeFileSync(`evidence/${name}.json`, JSON.stringify(value, null, 2));
if (mode === 'verify') {
  const source = fs.readFileSync('.setup-php/src/configs/pm/phpunit.json');
  assert.deepEqual(fs.readFileSync(installed), source);
  const config = JSON.parse(source);
  assert.equal(config.problemMatcher.length, 9);
  assert.equal(new Set(config.problemMatcher.map(x => x.owner)).size, 9);
  const sha = cp.execFileSync('git', ['-C', '.setup-php', 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim();
  assert.equal(sha, process.env.EXPECTED_ACTION_SHA);
  save('install', {sha, matcherSha256: crypto.createHash('sha256').update(source).digest('hex'), jobName: process.env.EVIDENCE_JOB_NAME, platform: process.platform, php: cp.execFileSync('php', ['--version'], {encoding: 'utf8'})});
  fs.copyFileSync(installed, 'evidence/phpunit.json');
} else if (mode === 'remove') {
  remove();
  for (const file of fs.readdirSync('evidence').filter(x => x.endsWith('-output.txt'))) process.stdout.write(fs.readFileSync(path.join('evidence', file)));
} else {
  let output, expected;
  if (mode === 'real') {
    const filters = {
      failures: 'test(PlainFailure|CustomFailure|ExplicitFailure|Exception|CustomMessageEndingInLocation|MultilineCustomMessage|DiffFailure)$',
      risky: 'test(Risky|SecondRisky|Incomplete)$',
      skips: 'testSkipped',
      issues: 'testUser(Warning|Notice)$'
    };
    const args = ['--colors=never', '--do-not-cache-result', ...(major === 9 ? ['--verbose'] : ['--display-skipped', '--display-incomplete', '--display-warnings', '--display-notices']), '--filter', filters[group], fixture];
    const result = cp.spawnSync('phpunit', args, {encoding: 'utf8', shell: process.platform === 'win32'});
    if (result.error) throw result.error;
    output = result.stdout + result.stderr;
    const expectedStatus = group === 'failures' || (group === 'issues' && major === 9) ? 2 : 0;
    assert.equal(result.status, expectedStatus, output);
    const summaries = {
      failures: 'Tests: 7, Assertions: 6, Errors: 1, Failures: 6.',
      risky: 'Tests: 3, Assertions: 0, Incomplete: 1, Risky: 2.',
      skips: 'Tests: 3, Assertions: 0, Skipped: 3.',
      issues: major === 9 ? 'Tests: 2, Assertions: 0, Errors: 2.' : 'Tests: 2, Assertions: 2, Warnings: 2, Notices: 2.'
    };
    assert.ok(output.includes(summaries[group]), output);
    save(`${group}-execution`, {major, status: result.status, args, summary: summaries[group]});
    expected = expectedReal(major, group);
  } else if (mode === 'layout') {
    ({output, expected} = layouts(group));
  } else throw new Error(`Unknown mode: ${mode}`);
  for (const severity of ['failure', 'warning', 'notice']) assert.ok(expected.filter(x => x.severity === severity).length <= 10, `${group}: annotation budget`);
  save(`${group}-expected`, expected);
  fs.writeFileSync(`evidence/${group}-output.txt`, output);
  if (order === 'same-step') register();
  process.stdout.write(output);
  if (order === 'same-step') {
    remove();
    process.stdout.write(output);
  }
}
