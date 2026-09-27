const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn, spawnSync} = require('node:child_process');
const {test} = require('node:test');

function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'php-darwin-files-')));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const prefix = path.join(root, 'prefix');
  const journals = path.join(root, 'journals');
  const write = (relative, data) => {const file = path.join(prefix, relative); fs.mkdirSync(path.dirname(file), {recursive: true}); fs.writeFileSync(file, data);};
  const link = (relative, target) => {const file = path.join(prefix, relative); fs.mkdirSync(path.dirname(file), {recursive: true}); fs.symlinkSync(target, file);};
  for (const file of ['bin/php', 'bin/phpize', 'include/php/main.h', 'lib/pkgconfig/php.pc']) write('Cellar/php/1.0/' + file, 'original');
  write('Cellar/php/1.0/INSTALL_RECEIPT.json', JSON.stringify({aliases: ['php@1'], runtime_dependencies: [], source: {tap: 'homebrew/core'}}));
  const links = {
    'bin/php': '../Cellar/php/1.0/bin/php',
    'bin/phpize': '../Cellar/other/1.0/bin/phpize',
    'include/php': '../Cellar/php/1.0/include/php',
    'lib/pkgconfig/php.pc': '../../Cellar/php/1.0/lib/pkgconfig/php.pc',
    'opt/php': '../Cellar/php/1.0',
    'opt/php@1': '../Cellar/php/1.0',
    'var/homebrew/linked/php': '../../../Cellar/php/1.0',
  };
  for (const [relative, target] of Object.entries(links)) link(relative, target);
  const args = mode => [path.join(__dirname, '../../installer/unlink-kegs.sh'), mode, prefix, journals, 'homebrew/core/php'];
  const run = mode => spawnSync('bash', args(mode), {encoding: 'utf8'});
  const check = () => {for (const [relative, target] of Object.entries(links)) assert.equal(fs.readlinkSync(path.join(prefix, relative)), target);};
  return {root, prefix, journals, write, link, links, args, run, check};
}

test('unlink preserves unrelated links, current aliases, opt records and keg contents; rollback restores exact targets', t => {
  const f = fixture(t);
  const result = f.run('unlink');
  assert.equal(result.status, 0, result.stderr);
  for (const relative of ['bin/php', 'include/php', 'lib/pkgconfig/php.pc', 'var/homebrew/linked/php']) assert.equal(fs.existsSync(path.join(f.prefix, relative)), false);
  for (const relative of ['bin/phpize', 'opt/php', 'opt/php@1']) assert.equal(fs.readlinkSync(path.join(f.prefix, relative)), f.links[relative]);
  assert.equal(fs.readFileSync(path.join(f.prefix, 'Cellar/php/1.0/bin/php'), 'utf8'), 'original');
  // The cache may create real directory parents where an old symlink stood.
  fs.mkdirSync(path.join(f.prefix, 'include/php/empty'), {recursive: true});
  const restored = f.run('restore');
  assert.equal(restored.status, 0, restored.stderr);
  f.check();
  assert.deepEqual(fs.readdirSync(f.journals), []);
});

test('rollback never overwrites a new user file', t => {
  const f = fixture(t);
  assert.equal(f.run('unlink').status, 0);
  f.write('bin/php', 'new user file');
  const result = f.run('restore');
  assert.equal(result.status, 1);
  assert.match(result.stderr, /rollback conflict/);
  assert.equal(fs.readFileSync(path.join(f.prefix, 'bin/php'), 'utf8'), 'new user file');
  assert.ok(fs.readdirSync(f.journals).length);
});

test('cached dependency replacement preserves unshipped links and refreshes extraction exclusions', t => {
  const f = fixture(t);
  f.write('Cellar/php/1.0/share/man/man1/php.1', 'old documentation');
  f.link('share/man/man1/php.1', '../../../Cellar/php/1.0/share/man/man1/php.1');
  f.write('Cellar/php/1.0/share/info/php.info', 'old info');
  f.link('share/info/php.info', '../../Cellar/php/1.0/share/info/php.info');
  const selected = path.join(f.root, 'selected');
  fs.writeFileSync(selected, 'bin/php\nopt/php\nvar/homebrew/linked/php\n');
  const kegs = path.join(f.root, 'kegs'); fs.writeFileSync(kegs, 'Cellar/php/2.0\n');
  const excluded = path.join(f.root, 'excluded');
  const inventory = () => spawnSync('bash', [path.join(__dirname, '../../installer/existing-paths.sh'), f.prefix,
    excluded, path.join(__dirname, '../../../conf/archive-paths'), path.join(f.root, 'existing-kegs'), selected, kegs], {encoding: 'utf8'});
  assert.equal(inventory().status, 0);
  assert.match(fs.readFileSync(excluded, 'utf8'), /^bin\/php$/m);
  const result = spawnSync('bash', f.args('unlink'), {
    encoding: 'utf8', env: {...process.env, PHP_DARWIN_UNLINK_PATHS_FILE: selected}
  });
  assert.equal(result.status, 0, result.stderr);
  for (const file of ['share/man/man1/php.1', 'share/info/php.info', 'include/php']) {
    assert.ok(fs.existsSync(path.join(f.prefix, file)), file);
  }
  assert.equal(inventory().status, 0);
  assert.doesNotMatch(fs.readFileSync(excluded, 'utf8'), /^(bin\/php|var\/homebrew\/linked\/php)$/m);
  // The refreshed list must let tar install the archived default and marker.
  const staging = path.join(f.root, 'archive');
  fs.mkdirSync(path.join(staging, 'Cellar/php/2.0/bin'), {recursive: true});
  fs.writeFileSync(path.join(staging, 'Cellar/php/2.0/bin/php'), 'new cached PHP');
  fs.mkdirSync(path.join(staging, 'bin'));
  fs.symlinkSync('../Cellar/php/2.0/bin/php', path.join(staging, 'bin/php'));
  fs.mkdirSync(path.join(staging, 'var/homebrew/linked'), {recursive: true});
  fs.symlinkSync('../../../Cellar/php/2.0', path.join(staging, 'var/homebrew/linked/php'));
  const archive = path.join(f.root, 'cache.tar');
  assert.equal(spawnSync('tar', ['-cf', archive, '-C', staging, 'Cellar/php/2.0/bin/php', 'bin/php', 'var/homebrew/linked/php']).status, 0);
  const extract = spawnSync('bash', [path.join(__dirname, '../../installer/extract.sh'), archive, f.prefix, excluded], {encoding: 'utf8'});
  assert.equal(extract.status, 0, extract.stderr);
  assert.equal(fs.readFileSync(path.join(f.prefix, 'bin/php'), 'utf8'), 'new cached PHP');
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'var/homebrew/linked/php')), '../../../Cellar/php/2.0');
  assert.equal(fs.readFileSync(path.join(f.prefix, 'Cellar/php/1.0/bin/php'), 'utf8'), 'original');
  assert.equal(fs.readFileSync(path.join(f.prefix, 'share/man/man1/php.1'), 'utf8'), 'old documentation');
});

test('selected dependency unlinking rejects unsafe paths before changing links', t => {
  const f = fixture(t);
  const selected = path.join(f.root, 'selected');
  for (const invalid of ['../escape', 'bin/../escape', '/bin/php', 'bin//php']) {
    fs.writeFileSync(selected, invalid + '\n');
    const result = spawnSync('bash', f.args('unlink'), {
      encoding: 'utf8', env: {...process.env, PHP_DARWIN_UNLINK_PATHS_FILE: selected}
    });
    assert.equal(result.status, 1, result.stderr);
    f.check();
  }
});

test('info-index maintenance delegates to Homebrew before any unlinking', t => {
  const f = fixture(t);
  f.write('Cellar/php/1.0/share/info/php.info', 'info fixture');
  f.link('share/info/php.info', '../../Cellar/php/1.0/share/info/php.info');
  const result = f.run('unlink');
  assert.equal(result.status, 78, result.stderr);
  f.check();
  assert.equal(fs.existsSync(f.journals), false);
});

test('stale aliases delegate before mutation', t => {
  const f = fixture(t);
  f.write('Cellar/php/0.9/fixture', 'old');
  f.link('opt/php@0', '../Cellar/php/0.9');
  assert.equal(f.run('unlink').status, 78);
  f.check();
  assert.equal(fs.existsSync(f.journals), false);
});

test('stale aliases of other PHP variants do not block unlinking the active rack', t => {
  const f = fixture(t);
  f.link('opt/php@1-debug', '../Cellar/php-debug/1.0');
  f.link('opt/php@1-zts', '../Cellar/php-zts/1.0');
  const result = f.run('unlink');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(path.join(f.prefix, 'bin/php')), false);
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'opt/php@1-debug')), '../Cellar/php-debug/1.0');
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'opt/php@1-zts')), '../Cellar/php-zts/1.0');
  assert.equal(f.run('restore').status, 0);
  f.check();
});

test('owned unversioned aliases are journaled and restored; unrelated aliases are preserved', t => {
  const f = fixture(t);
  f.write('Cellar/php/1.0/INSTALL_RECEIPT.json', JSON.stringify({aliases: ['php@1', 'php-alias', 'other-alias'], runtime_dependencies: []}));
  f.link('opt/php-alias', '../Cellar/php/1.0');
  f.link('var/homebrew/linked/php-alias', '../../../Cellar/php/1.0');
  f.write('Cellar/other/1.0/fixture', 'other package');
  f.link('opt/other-alias', '../Cellar/other/1.0');
  let result = f.run('unlink');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(path.join(f.prefix, 'opt/php-alias')), false);
  assert.equal(fs.existsSync(path.join(f.prefix, 'var/homebrew/linked/php-alias')), false);
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'opt/php@1')), '../Cellar/php/1.0');
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'opt/other-alias')), '../Cellar/other/1.0');
  result = f.run('restore');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'opt/php-alias')), '../Cellar/php/1.0');
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'var/homebrew/linked/php-alias')), '../../../Cellar/php/1.0');
  f.check();
});

test('an alias represented by a real user file delegates before modifying anything', t => {
  const f = fixture(t);
  f.write('Cellar/php/1.0/INSTALL_RECEIPT.json', JSON.stringify({aliases: ['php-alias']}));
  f.write('opt/php-alias', 'user content');
  assert.equal(f.run('unlink').status, 78);
  assert.equal(fs.readFileSync(path.join(f.prefix, 'opt/php-alias'), 'utf8'), 'user content');
  f.check();
  assert.equal(fs.existsSync(f.journals), false);
});

test('symlinked parents outside the selected keg are left to Homebrew', t => {
  const f = fixture(t);
  fs.unlinkSync(path.join(f.prefix, 'include/php'));
  f.link('include/php', '../Cellar/other/1.0/include/php');
  assert.equal(f.run('unlink').status, 78);
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'bin/php')), f.links['bin/php']);
});

test('unlink respects Homebrew formula locks', async t => {
  const f = fixture(t);
  const lockDir = path.join(f.prefix, 'var/homebrew/locks'); fs.mkdirSync(lockDir, {recursive: true});
  const ready = path.join(f.root, 'ready');
  const writer = spawn('/usr/bin/ruby', ['-e', "File.open(ARGV[0], File::RDWR|File::CREAT, 0644) { |f| f.flock(File::LOCK_EX); File.write(ARGV[1], 'ready'); sleep 0.7 }", path.join(lockDir, 'php.formula.lock'), ready]);
  const done = new Promise(resolve => writer.on('close', resolve));
  while (!fs.existsSync(ready)) await new Promise(resolve => setTimeout(resolve, 10));
  const result = f.run('unlink');
  assert.equal(result.status, 1);
  assert.match(result.stderr, /formula is busy/);
  f.check();
  assert.equal(fs.existsSync(f.journals), false);
  assert.equal(await done, 0);
});

test('dependency validation checks transitive receipt dependencies and opt aliases', t => {
  const f = fixture(t);
  f.write('Cellar/php/1.0/INSTALL_RECEIPT.json', JSON.stringify({runtime_dependencies: [{full_name: 'example/libraries/libxml2'}]}));
  f.write('Cellar/libxml2/2.0/INSTALL_RECEIPT.json', JSON.stringify({runtime_dependencies: [{full_name: 'openssl@3'}]}));
  const packages = path.join(f.root, 'packages');
  fs.writeFileSync(packages, 'php\t../Cellar/php/1.0\tfalse\nlibxml2\t../Cellar/libxml2/2.0\ttrue\n');
  const run = () => spawnSync('bash', [path.join(__dirname, '../../installer/check-dependencies.sh'), f.prefix, packages], {encoding: 'utf8'});
  let result = run();
  assert.equal(result.status, 1, result.stderr);
  assert.equal(result.stdout.trim(), 'openssl@3');
  f.write('Cellar/openssl/3.0/fixture', 'library');
  f.link('opt/openssl@3', '../Cellar/openssl/3.0');
  result = run();
  assert.equal(result.status, 0, result.stderr);
  f.write('Cellar/libxml2/2.0/INSTALL_RECEIPT.json', JSON.stringify({runtime_dependencies: null}));
  assert.equal(run().status, 78);
  f.write('Cellar/libxml2/2.0/INSTALL_RECEIPT.json', '{invalid');
  result = run();
  assert.equal(result.status, 1);
  assert.match(result.stderr, /dependency receipts/);
});
