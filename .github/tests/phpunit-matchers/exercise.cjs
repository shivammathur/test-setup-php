const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const fixture = '.github/tests/phpunit-matchers/OutcomesTest.php';
const installed = path.join(process.env.RUNNER_TOOL_CACHE || '.', 'phpunit.json');
const mode = process.argv[2];
const label = process.argv[3] || mode;
const register = () => console.log(`::add-matcher::${installed}`);
const remove = () => console.log(`::remove-matcher::${installed}`);
fs.mkdirSync('evidence', {recursive: true});

function save(name, value) {
  fs.writeFileSync(`evidence/${name}.json`, JSON.stringify(value, null, 2));
}

if (mode === 'verify') {
  const source = fs.readFileSync('.setup-php/src/configs/pm/phpunit.json');
  assert.deepEqual(fs.readFileSync(installed), source);
  const config = JSON.parse(source);
  assert.equal(config.problemMatcher.length, 9);
  assert.equal(new Set(config.problemMatcher.map(x => x.owner)).size, 9);
  const sha = cp.execFileSync('git', ['-C', '.setup-php', 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim();
  assert.equal(sha, process.env.EXPECTED_ACTION_SHA);
  save('install', {sha, matcherSha256: crypto.createHash('sha256').update(source).digest('hex'), platform: process.platform, php: cp.execFileSync('php', ['--version'], {encoding: 'utf8'})});
  fs.copyFileSync(installed, 'evidence/phpunit.json');
} else if (mode === 'real') {
  const major = Number(process.argv[4]);
  if (label === 'same-step') register();
  const args = ['--colors=never', '--do-not-cache-result', ...(major === 9 ? ['--verbose'] : ['--display-skipped', '--display-incomplete', '--display-warnings', '--display-notices']), fixture];
  const result = cp.spawnSync('phpunit', args, {encoding: 'utf8', shell: process.platform === 'win32'});
  if (result.error) throw result.error;
  fs.writeFileSync(`evidence/${label}-output.txt`, result.stdout + result.stderr);
  save(`${label}-exit`, {major, status: result.status, args});
  assert.equal(result.status, 2);
  assert.match(result.stdout, major === 9
    ? /Tests: 14, Assertions: 6, Errors: 3, Failures: 6, Skipped: 3, Incomplete: 1, Risky: 1\./
    : /Tests: 14, Assertions: 8, Errors: 1, Failures: 6, Warnings: 2, Notices: 2, Skipped: 3, Incomplete: 1, Risky: 1\./);
  const failures = [
    [25, 'RuntimeException: PR1138 unexpected exception'],
    [10, 'Failed asserting that false is true.'],
    [15, 'PR1138 custom assertion message'],
    [20, 'PR1138 explicit failure'],
    [52, 'PR1138 invalid attribute in template.php:42'],
    [57, 'PR1138 multiline assertion message'],
    [62, 'PR1138 assertion with diff']
  ].map(([line, message]) => ({message, severity: 'failure', file: fixture, line}));
  const expected = [
    ...failures,
    {message: '1) OutcomesTest::testRisky', severity: 'warning', file: null, line: null},
    ...['1) OutcomesTest::testIncomplete', '1) OutcomesTest::testSkippedReason', '2) OutcomesTest::testSkippedNoReason', '3) OutcomesTest::testSkippedDependency']
      .map(message => ({message, severity: 'notice', file: null, line: null}))
  ];
  if (major === 9) {
    // PHPUnit 9 reports these as test errors; preserve its reported outcome.
    expected.push(
      {message: 'PR1138 native user warning', severity: 'failure', file: fixture, line: 72},
      {message: 'PR1138 native user notice', severity: 'failure', file: fixture, line: 79}
    );
  } else {
    for (const [line, severity] of [[72, 'warning'], [73, 'warning'], [79, 'notice'], [80, 'notice']]) {
      expected.push({message: `${path.resolve(fixture)}:${line}`, severity, file: fixture, line});
    }
  }
  save(`${label}-expected`, expected);
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  remove();
  // Any annotation from this replay makes the exact annotation audit fail.
  process.stdout.write(result.stdout);
} else {
  throw new Error(`Unknown mode: ${mode}`);
}
