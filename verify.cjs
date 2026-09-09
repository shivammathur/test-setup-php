const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');

const action = path.join(
  process.env.GITHUB_WORKSPACE, '..', '..', '_actions',
  'shivammathur', 'setup-php', process.env.ACTION_COMMIT
);
const source = path.join(action, 'src');
const extension = process.platform === 'win32' ? '.ps1' : '.sh';
const results = path.join(process.cwd(), 'results');
const statePath = path.join(results, 'state.json');
const pipe = />[ \t]*(?:\/dev\/null|\$null)[ \t]+2>&1/g;
const copies = () => fs.readdirSync(action).filter(name => name.startsWith('src-verbose-')).sort();
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const sourceFiles = () => fs.readdirSync(path.join(source, 'scripts'), {recursive: true})
  .filter(file => file.endsWith(extension) && path.basename(file) !== 'run' + extension);

assert(fs.existsSync(source), 'Cannot find the downloaded action: ' + source);
fs.mkdirSync(results, {recursive: true});
if (process.argv[2] === 'before') {
  const hashes = Object.fromEntries(sourceFiles().map(file => [file, hash(path.join(source, 'scripts', file))]));
  fs.writeFileSync(statePath, JSON.stringify({copies: copies(), hashes, cases: []}, null, 2));
  console.log('Snapshot ready: action scripts are outside GITHUB_WORKSPACE.');
  process.exit(0);
}

const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
const config = JSON.parse(process.env.CASE_ENV);
const level = config.verbose || config.VERBOSE || '';
const enabled = ['true', 'v', 'vv', 'vvv'].includes(level) || config.RUNNER_DEBUG === '1';
const trace = level === 'vv' ? 1 : level === 'vvv' ? 2 : 0;
const currentCopies = copies();
const created = currentCopies.filter(name => !state.copies.includes(name));
assert.equal(created.length, enabled ? 1 : 0, 'Wrong number of verbose copies');
const active = enabled ? path.join(action, created[0]) : source;
const runner = path.join(active, 'scripts', 'run' + extension);
const content = fs.readFileSync(runner, 'utf8');
assert.match(content, new RegExp(active.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
let sourceSinks = 0;
let runtimeSinks = 0;
for (const [file, originalHash] of Object.entries(state.hashes)) {
  const originalFile = path.join(source, 'scripts', file);
  const original = fs.readFileSync(originalFile, 'utf8');
  assert.equal(hash(originalFile), originalHash, 'Original source changed: ' + file);
  const runtime = fs.readFileSync(path.join(active, 'scripts', file), 'utf8');
  sourceSinks += [...original.matchAll(pipe)].length;
  runtimeSinks += [...runtime.matchAll(pipe)].length;
  assert.equal(runtime, enabled ? original.replace(pipe, '') : original, 'Unexpected runtime transformation: ' + file);
}
assert(sourceSinks > 0, 'The source fixture has no existing suppression sites');
assert.equal(runtimeSinks, enabled ? 0 : sourceSinks);
const originalRunner = fs.readFileSync(path.join(source, 'scripts', 'run' + extension), 'utf8');
assert.equal(content, enabled ? originalRunner.replace(pipe, '').replaceAll(source, active) : originalRunner, 'Unexpected generated runner transformation');
if (enabled) assert(!content.includes(path.join(source, 'scripts')), 'Runner still sources the original scripts');
assert.match(process.env.PHP_VERSION, /^8\.4\./, 'Wrong action output');
const php = spawnSync('php', ['-r', 'if (PHP_MAJOR_VERSION !== 8 || PHP_MINOR_VERSION !== 4 || ini_get("post_max_size") !== "256M") { exit(1); } echo PHP_VERSION;'], {encoding: 'utf8'});
assert.equal(php.status, 0, 'PHP/configuration validation failed: ' + php.stderr);
const record = {
  os: process.env.TEST_OS, mode: process.env.TEST_MODE, phase: process.argv[3], config,
  enabled, trace, runner, created, sourceSinks, runtimeSinks, phpVersion: php.stdout
};
state.copies = currentCopies;
state.cases.push(record);
fs.writeFileSync(statePath, JSON.stringify(state, null, 2));
fs.writeFileSync(path.join(results, process.argv[3] + '.json'), JSON.stringify(record, null, 2));
console.log(JSON.stringify(record));
