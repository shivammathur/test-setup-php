const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {runSetupPhp} = require('./.cache-tests/scripts/tests/helpers/run-setup-php.cjs');
assert.equal(process.env.GITHUB_ACTIONS, 'true');
const directory = path.resolve('profile');
fs.mkdirSync(directory, {recursive: true});
process.env.PROFILE_DIR = directory;
process.env.PHP_DARWIN_TEST_TIMINGS = path.join(directory, 'action.jsonl');
process.env.PHP_DARWIN_TEST_LABEL = process.env.SCENARIO;
process.env.PHP_DARWIN_TEST_PHASE = 'cold-with-brew-extensions';
const script = '.setup-php/src/scripts/darwin.sh';
const source = fs.readFileSync(script, 'utf8');
assert.equal(source.split('\nsetup_php\n').length, 2);
fs.writeFileSync(script, source.replace('\nsetup_php\n', '\n' + fs.readFileSync('profile.sh', 'utf8') + '\nsetup_php\n'));
const command = (program, args) => execFileSync(program, args, {encoding: 'utf8'}).trim();
const prefix = command('brew', ['--prefix']);
const repository = command('brew', ['--repository']);
function revisions() {
  const result = {};
  for (const [name, dir] of [['brew', repository], ['core', path.join(repository, 'Library/Taps/homebrew/homebrew-core')]]) {
    if (fs.existsSync(path.join(dir, '.git'))) result[name] = command('git', ['-C', dir, 'rev-parse', 'HEAD']);
  }
  return result;
}
const before = revisions();
fs.writeFileSync(path.join(directory, 'revisions-before.json'), JSON.stringify(before));
const status = runSetupPhp('.setup-php');
const stages = fs.readFileSync(path.join(directory, 'stages.tsv'), 'utf8').trim().split('\n').map(line => {
  const [name, start, end, status, args] = line.split('\t');
  return {name, seconds: Number(end) - Number(start), status: Number(status), args};
});
const after = revisions();
fs.writeFileSync(path.join(directory, 'result.json'), JSON.stringify({scenario: process.env.SCENARIO, architecture: process.arch, status, before, after, stages}, null, 2));
console.log(JSON.stringify(stages.filter(stage => ['add_brew_extension', 'update_dependencies', 'git_retry'].includes(stage.name)), null, 2));
assert.equal(status, 0);
assert.ok(stages.some(stage => stage.name === 'setup_cached_versions' && stage.status === 0));
assert.equal(command('shasum', ['-a', '256', command('which', ['php'])]), fs.readFileSync(path.join(directory, 'php-before.sha256'), 'utf8').trim());
for (const name of process.env.INPUT_EXTENSIONS.split(',').map(name => name.trim())) {
  assert.match(command('brew', ['list', '--versions', `shivammathur/extensions/${name}@8.4`]), new RegExp(`${name}@8.4`));
}
console.log(command('php', ['-r', `
  $r = new Redis(); $value = ['cache' => [42, true, null]];
  foreach ([Redis::SERIALIZER_IGBINARY, Redis::SERIALIZER_MSGPACK] as $serializer) {
    if (!$r->setOption(Redis::OPT_SERIALIZER, $serializer) || $r->_unserialize($r->_serialize($value)) !== $value) exit(1);
  }
  if (getenv('SCENARIO') !== 'debug-zts' && (yaml_parse("cache: 42")['cache'] !== 42 || !extension_loaded('apcu'))) exit(1);
  if (getenv('SCENARIO') === 'debug-zts' && (!PHP_ZTS || !PHP_DEBUG)) exit(1);
  echo "Brew modules and serializers passed; PHP binary unchanged\\n";
`]));
const refreshes = stages.filter(stage => stage.name === 'update_dependencies');
if (process.env.SCENARIO === 'baseline') assert.ok(refreshes.length >= 1);
if (process.env.SCENARIO === 'recovery') {
  assert.ok(fs.existsSync(path.join(directory, 'injected')));
  assert.equal(refreshes.length, 1);
  assert.equal(refreshes[0].status, 0);
  assert.equal(stages.filter(stage => stage.name === 'brew' && stage.status !== 0).length, 1);
}
if (!refreshes.length) assert.deepEqual(after, before);
assert.ok(fs.readdirSync(path.join(prefix, 'var/php-darwin')).some(name => name.startsWith('php_8.4-')));
