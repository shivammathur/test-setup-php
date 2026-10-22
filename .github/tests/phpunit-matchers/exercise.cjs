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

function layouts(prefix) {
  const at = line => `${path.resolve(fixture)}:${line}`;
  const assertion = 'Failed asserting that false is true.';
  const cases = [
    ['plainBlank', 'failure', 10, `${assertion} [${prefix}-blank]`, '', at(10)],
    ['plainNoBlank', 'failure', 15, `${assertion} [${prefix}-no-blank]`, at(15)],
    ['customNoBlank', 'failure', 20, `${prefix} custom no blank`, assertion, at(20)],
    ['customBlank', 'failure', 25, `${prefix} custom blank`, assertion, '', at(25)],
    ['explicitFailure', 'failure', 20, `${prefix} explicit failure`, '', at(20)],
    ['exception', 'failure', 25, `RuntimeException: ${prefix} exception`, '', at(25)],
    ['customLocation', 'failure', 52, `${prefix} invalid template.php:42`, assertion, '', at(52)],
    ['riskyBlank', 'warning', null, 'This test did not perform any assertions', '', at(30)],
    ['skippedReasonNoBlank', 'warning', null, `${prefix} skipped reason`, at(35)],
    ['skippedNoReasonNoBlank', 'warning', null, at(40)],
    ['skippedDependency', 'warning', null, 'This test depends on "Layout::provider" to pass'],
    ['skippedNoReasonBlank', 'warning', null, '', at(40)],
    ['skippedReasonBlank', 'warning', null, `${prefix} skipped reason with blank`, '', at(35)],
    ['riskyNoBlank', 'warning', null, 'This test did not perform any assertions', at(30)]
  ];
  const expected = [];
  const output = [];
  for (const [name, severity, line, ...body] of cases) {
    const header = `1) Layout::${prefix}_${name}`;
    const section = severity === 'failure' ? 'There was 1 failure:' : name.startsWith('risky') ? 'There was 1 risky test:' : 'There was 1 skipped test:';
    output.push(section, '', header, ...body, '', '--', '');
    expected.push({message: severity === 'failure' ? body[0] : header, severity, file: line ? fixture : null, line});
  }
  return {output: output.join('\n') + '\n', expected};
}

if (mode === 'verify') {
  const source = fs.readFileSync('.setup-php/src/configs/pm/phpunit.json');
  assert.deepEqual(fs.readFileSync(installed), source);
  const config = JSON.parse(source);
  assert.equal(config.problemMatcher.length, 7);
  assert.equal(new Set(config.problemMatcher.map(x => x.owner)).size, 7);
  const sha = cp.execFileSync('git', ['-C', '.setup-php', 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim();
  assert.equal(sha, process.env.EXPECTED_ACTION_SHA);
  save('install', {sha, matcherSha256: crypto.createHash('sha256').update(source).digest('hex'), platform: process.platform, php: cp.execFileSync('php', ['--version'], {encoding: 'utf8'})});
  fs.copyFileSync(installed, 'evidence/phpunit.json');
} else if (mode === 'layouts' || mode === 'removed') {
  if (label === 'same-step') register();
  const cases = layouts(mode === 'removed' ? 'after-removal' : label);
  save(`${label}-expected`, mode === 'removed' ? [] : cases.expected);
  fs.writeFileSync(`evidence/${label}-output.txt`, cases.output);
  process.stdout.write(cases.output);
  if (label === 'same-step') {
    remove();
    process.stdout.write(layouts('after-same-step-removal').output);
  }
} else if (mode === 'real') {
  const major = Number(process.argv[4]);
  if (label === 'same-step') register();
  const args = ['--colors=never', '--do-not-cache-result', ...(major === 9 ? ['--verbose'] : ['--display-skipped', '--display-incomplete']), fixture];
  const result = cp.spawnSync('phpunit', args, {encoding: 'utf8', shell: process.platform === 'win32'});
  if (result.error) throw result.error;
  fs.writeFileSync(`evidence/${label}-output.txt`, result.stdout + result.stderr);
  save(`${label}-exit`, {major, status: result.status, args});
  assert.equal(result.status, 2);
  assert.match(result.stdout, /Tests: 12, Assertions: 6, Errors: 1, Failures: 6, Skipped: 3, Incomplete: 1, Risky: 1\./);
  const failures = [
    [25, 'RuntimeException: PR1138 unexpected exception'],
    [10, 'Failed asserting that false is true.'],
    [15, 'PR1138 custom assertion message'],
    [20, 'PR1138 explicit failure'],
    [52, 'PR1138 invalid attribute in template.php:42'],
    [57, 'PR1138 multiline assertion message'],
    [62, 'PR1138 assertion with diff']
  ].map(([line, message]) => ({message, severity: 'failure', file: fixture, line}));
  const warnings = ['1) OutcomesTest::testRisky', '1) OutcomesTest::testIncomplete', '1) OutcomesTest::testSkippedReason', '2) OutcomesTest::testSkippedNoReason', '3) OutcomesTest::testSkippedDependency']
    .map(message => ({message, severity: 'warning', file: null, line: null}));
  save(`${label}-expected`, [...failures, ...warnings]);
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  remove();
  // Any annotation from this replay makes the exact annotation audit fail.
  process.stdout.write(result.stdout);
} else {
  throw new Error(`Unknown mode: ${mode}`);
}
