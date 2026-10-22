const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const assert = require('node:assert/strict');

const source = '.setup-php/src/configs/pm/phpunit.json';
const installed = path.join(process.env.RUNNER_TOOL_CACHE || '.', 'phpunit.json');
const mode = process.argv[2];
fs.mkdirSync('evidence', {recursive: true});

function emit(name, lines) {
  const output = lines.join('\n') + '\n';
  fs.writeFileSync(`evidence/${name}.txt`, output);
  process.stdout.write(output);
}

function layouts(prefix = 'layout') {
  const file = path.resolve('fixtures/OutcomesTest.php');
  const at = line => `${file}:${line}`;
  return [
    {owner: 'phpunit', severity: 'failure', line: 10,
      message: `Failed asserting that false is true. [${prefix}-blank]`,
      lines: ['1) Layout::plainBlank', `Failed asserting that false is true. [${prefix}-blank]`, '', at(10)]},
    {owner: 'phpunit-no-blank', severity: 'failure', line: 15,
      message: `Failed asserting that false is true. [${prefix}-no-blank]`,
      lines: ['2) Layout::plainNoBlank', `Failed asserting that false is true. [${prefix}-no-blank]`, at(15)]},
    {owner: 'phpunit-custom-message', severity: 'failure', line: 20,
      message: `${prefix} custom message without blank`,
      lines: ['3) Layout::customNoBlank', `${prefix} custom message without blank`, 'Failed asserting that false is true.', at(20)]},
    {owner: 'phpunit-custom-message-blank', severity: 'failure', line: 25,
      message: `${prefix} custom message with blank`,
      lines: ['4) Layout::customBlank', `${prefix} custom message with blank`, 'Failed asserting that false is true.', '', at(25)]},
    {owner: 'phpunit-other-blank', severity: 'warning', line: 30,
      message: `${prefix} risky test did not perform assertions`,
      lines: ['5) Layout::riskyBlank', `${prefix} risky test did not perform assertions`, '', at(30)]},
    {owner: 'phpunit-other', severity: 'warning', line: 35,
      message: `${prefix} skipped with reason`,
      lines: ['6) Layout::skippedReason', `${prefix} skipped with reason`, at(35)]},
    {owner: 'phpunit-skipped-no-reason', severity: 'warning', line: 40,
      message: `7) Layout::${prefix}SkippedNoReason`,
      lines: [`7) Layout::${prefix}SkippedNoReason`, at(40)]},
    {owner: 'phpunit-skipped-depends', severity: 'warning', line: null,
      message: `This test depends on "Layout::${prefix}SkippedNoReason" to pass.`,
      lines: ['8) Layout::skippedDependency', `This test depends on "Layout::${prefix}SkippedNoReason" to pass.`]}
  ];
}

if (mode === 'verify') {
  assert.deepEqual(fs.readFileSync(installed), fs.readFileSync(source));
  const config = JSON.parse(fs.readFileSync(installed));
  assert.equal(config.problemMatcher.length, 8);
  assert.equal(new Set(config.problemMatcher.map(x => x.owner)).size, 8);
  for (const matcher of config.problemMatcher) {
    for (const pattern of matcher.pattern) new RegExp(pattern.regexp);
  }
  const report = {
    sha: cp.execFileSync('git', ['-C', '.setup-php', 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(),
    matcherSha256: crypto.createHash('sha256').update(fs.readFileSync(installed)).digest('hex'),
    owners: config.problemMatcher.map(x => x.owner),
    platform: process.platform,
    php: cp.execFileSync('php', ['--version'], {encoding: 'utf8'}),
  };
  assert.equal(report.sha, '82bc8cd79fee22fe271046833ce98e50c7e1d5a2');
  fs.writeFileSync('evidence/install.json', JSON.stringify(report, null, 2));
  fs.copyFileSync(installed, 'evidence/phpunit.json');
  console.log(JSON.stringify(report, null, 2));
} else if (mode === 'layouts' || mode === 'removed') {
  const cases = layouts(mode === 'removed' ? 'after-removal' : 'layout');
  fs.writeFileSync(`evidence/${mode}-expected.json`, JSON.stringify(mode === 'removed' ? [] : cases.map(({lines, ...item}) => item), null, 2));
  emit(mode, cases.flatMap(item => [...item.lines, '']));
} else if (mode === 'edge-cases') {
  const file = path.resolve('fixtures/OutcomesTest.php');
  emit(mode, [
    '1) Layout::failureWithoutFailedAsserting', 'PR1138 explicit fail synthetic', '', `${file}:20`, '',
    '2) Layout::exception', 'RuntimeException: PR1138 exception synthetic', '', `${file}:25`, '',
    '3) Layout::customLocation', 'PR1138 custom message ends template.php:42', 'Failed asserting that false is true.', '', `${file}:52`, '',
    '4) Layout::emptySkipWithBlank', '', `${file}:40`, '',
    '5) Layout::skipReasonWithBlank', 'PR1138 skipped reason blank', '', `${file}:35`, '',
    '6) Layout::riskyReasonNoBlank', 'PR1138 risky reason no blank', `${file}:30`, ''
  ]);
} else if (mode === 'real') {
  const major = Number(process.argv[3]);
  const args = ['--colors=never', '--do-not-cache-result'];
  args.push(...(major === 9 ? ['--verbose'] : ['--display-skipped', '--display-incomplete']));
  args.push('fixtures/OutcomesTest.php');
  const result = cp.spawnSync('phpunit', args, {encoding: 'utf8', shell: process.platform === 'win32'});
  if (result.error) throw result.error;
  fs.writeFileSync('evidence/phpunit-output.txt', result.stdout + result.stderr);
  fs.writeFileSync('evidence/phpunit-exit.json', JSON.stringify({major, status: result.status, args}, null, 2));
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  assert.ok(result.status === 1 || result.status === 2, `Expected deliberate PHPUnit failures, got ${result.status}`);
  for (const expected of ['PR1138 custom assertion message', 'PR1138 explicit failure', 'PR1138 unexpected exception', 'PR1138 skipped with reason', 'PR1138 incomplete test']) {
    assert.ok(result.stdout.includes(expected), `Missing fixture output: ${expected}`);
  }
  assert.match(result.stdout, /Tests: 12/);
  console.log(`Captured deliberate PHPUnit ${major} failures (exit ${result.status}).`);
} else {
  throw new Error(`Unknown mode: ${mode}`);
}
