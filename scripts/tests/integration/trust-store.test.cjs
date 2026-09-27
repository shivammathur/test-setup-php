const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn, spawnSync} = require('node:child_process');
const {test} = require('node:test');

const helper = path.join(__dirname, '../../installer/trust-store.sh');
// Fixture for the recognized storage protocol. Native CI also checks the
// resulting files through the actual Homebrew trust and formula-loading APIs.
const protocol = `
    tap: :trustedtaps, formula: :trustedformulae, cask: :trustedcasks, command: :trustedcommands
    def self.trust_file
      HOMEBREW_USER_CONFIG_HOME .homebrew/trust.json user_config_home/"trust.json"
    end
    def self.setting_key
      SETTING_KEYS.fetch(type).to_s
    end
    def self.normalise_name
      name.downcase
    end
    def self.trust_store
      JSON.parse(trust_path.read) parsed_store.transform_values
    end
    def self.write_trust_store
      write_path.atomic_write write_path.chmod(0600)
    end
    def self.with_trust_store_lock
      "#{trust_file}.lock" File::RDWR | File::CREAT, 0600 lock_file.flock(File::LOCK_EX)
    end
`;

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'php-darwin-trust-test-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const prefix = path.join(root, 'brew');
  const config = path.join(root, 'config/homebrew');
  const source = path.join(prefix, 'Library/Homebrew/trust.rb');
  const tap = path.join(prefix, 'Library/Taps/example/homebrew-php');
  for (const directory of [config, path.dirname(source), path.join(prefix, 'bin'), path.join(tap, 'Formula')]) {
    fs.mkdirSync(directory, {recursive: true, mode: 0o700});
  }
  fs.writeFileSync(source, protocol);
  fs.writeFileSync(path.join(prefix, 'bin/brew'), 'fixture');
  spawnSync('git', ['init', '-q', tap]);
  spawnSync('git', ['-C', tap, 'remote', 'add', 'origin', 'https://github.com/example/homebrew-php']);
  for (const name of ['php', 'php@8.4', 'php@8.6']) fs.writeFileSync(path.join(tap, 'Formula', name + '.rb'), 'fixture');
  const store = path.join(config, 'trust.json');
  const journal = path.join(root, 'added');
  const env = {...process.env, HOME: root, XDG_CONFIG_HOME: path.dirname(config)};
  for (const name of ['HOMEBREW_FORCE_BREW_WRAPPER', 'HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY', 'HOMEBREW_XDG_CONFIG_HOME']) delete env[name];
  const args = (mode, references = ['example/php/php']) => [helper, mode, prefix, 'example/php', journal, ...references];
  const run = (mode, references) => spawnSync('bash', args(mode, references), {env, encoding: 'utf8'});
  const write = value => fs.writeFileSync(store, JSON.stringify(value), {mode: 0o600});
  const read = () => JSON.parse(fs.readFileSync(store, 'utf8'));
  return {root, prefix, config, source, tap, store, journal, env, args, run, write, read};
}

test('snapshot is read-only; merge preserves every other trust collection; rollback removes only additions', t => {
  const f = fixture(t);
  const original = {trustedtaps: ['another/tap'], trustedformulae: ['example/php/php@8.4'], trustedcasks: ['other/apps/tool'], trustedcommands: ['other/tap/cmd']};
  f.write(original);
  const bytes = fs.readFileSync(f.store);
  const snapshot = f.run('snapshot');
  assert.equal(snapshot.status, 0, snapshot.stderr);
  assert.deepEqual(JSON.parse(snapshot.stdout), {taps: original.trustedtaps, formulae: original.trustedformulae});
  assert.deepEqual(fs.readFileSync(f.store), bytes);
  const merged = f.run('add', ['example/php/php', 'example/php/php@8.4']);
  assert.equal(merged.status, 0, merged.stderr);
  assert.deepEqual(f.read(), {...original, trustedformulae: ['example/php/php', 'example/php/php@8.4']});
  assert.equal(fs.readFileSync(f.journal, 'utf8'), 'example/php/php\n');
  assert.equal(fs.statSync(f.store).mode & 0o777, 0o600);
  assert.equal(f.run('remove').status, 0);
  assert.deepEqual(f.read(), original);
});

test('empty store is created securely and removed on rollback', t => {
  const f = fixture(t);
  fs.rmdirSync(f.config);
  assert.equal(f.run('snapshot').status, 0);
  assert.equal(fs.existsSync(f.config), false);
  assert.equal(f.run('add').status, 0);
  assert.equal(fs.statSync(f.config).mode & 0o777, 0o700);
  assert.equal(f.run('remove').status, 0);
  assert.equal(fs.existsSync(f.store), false);
});

test('existing formula and whole-tap trust produce an empty rollback delta', t => {
  const f = fixture(t);
  for (const original of [{trustedformulae: ['EXAMPLE/PHP/PHP']}, {trustedtaps: ['example/php']}]) {
    f.write(original);
    const bytes = fs.readFileSync(f.store);
    assert.equal(f.run('add').status, 0);
    assert.deepEqual(fs.readFileSync(f.store), bytes);
    assert.equal(fs.readFileSync(f.journal, 'utf8'), '');
  }
});

test('unsupported protocol, schema, brew.env, symlinks and custom remotes use the CLI without mutations', t => {
  const f = fixture(t);
  f.write({trustedformulae: []});
  const check = (change, restore) => {
    change();
    const bytes = fs.readFileSync(f.store);
    const result = f.run('add');
    assert.equal(result.status, 78, result.stderr);
    assert.deepEqual(fs.readFileSync(f.store), bytes);
    assert.equal(fs.existsSync(f.journal), false);
    restore();
  };
  check(() => fs.writeFileSync(f.source, protocol.replace('File::LOCK_EX', 'UNKNOWN_LOCK')), () => fs.writeFileSync(f.source, protocol));
  check(() => f.write({schema: 2}), () => f.write({trustedformulae: []}));
  check(() => fs.writeFileSync(path.join(f.config, 'brew.env'), ''), () => fs.unlinkSync(path.join(f.config, 'brew.env')));
  check(() => {fs.renameSync(f.store, f.store + '.target'); fs.symlinkSync(f.store + '.target', f.store);}, () => {fs.unlinkSync(f.store); fs.renameSync(f.store + '.target', f.store);});
  check(() => spawnSync('git', ['-C', f.tap, 'remote', 'set-url', 'origin', 'https://example.invalid/other']), () => {});
});

test('malformed JSON, writable trust stores and invalid references fail without replacing contents', t => {
  const f = fixture(t);
  fs.writeFileSync(f.store, '{invalid');
  assert.equal(f.run('add').status, 1);
  assert.equal(fs.readFileSync(f.store, 'utf8'), '{invalid');
  f.write({trustedformulae: []});
  fs.chmodSync(f.store, 0o666);
  assert.equal(f.run('add').status, 1);
  fs.chmodSync(f.store, 0o600);
  assert.equal(f.run('add', ['other/tap/formula']).status, 1);
  assert.deepEqual(f.read(), {trustedformulae: []});
});

test('concurrent writers share the Homebrew flock and the journal excludes concurrent additions', async t => {
  const f = fixture(t);
  const ready = path.join(f.root, 'ready');
  const writer = spawn('/usr/bin/ruby', ['-e', `require 'json'; File.open(ARGV[0], File::RDWR|File::CREAT, 0600) { |f| f.flock(File::LOCK_EX); File.write(ARGV[2], 'ready'); sleep 0.5; File.write(ARGV[1], JSON.generate({'trustedformulae'=>['example/php/php@8.4'], 'trustedtaps'=>['concurrent/tap']})) }`, f.store + '.lock', f.store, ready]);
  const writerDone = new Promise(resolve => writer.on('close', resolve));
  while (!fs.existsSync(ready)) await new Promise(resolve => setTimeout(resolve, 10));
  const child = spawn('bash', f.args('add', ['example/php/php', 'example/php/php@8.4']), {env: f.env});
  let stderr = '';
  child.stderr.on('data', bytes => {stderr += bytes;});
  assert.equal(await new Promise(resolve => child.on('close', resolve)), 0, stderr);
  assert.equal(await writerDone, 0);
  assert.deepEqual(f.read(), {trustedformulae: ['example/php/php', 'example/php/php@8.4'], trustedtaps: ['concurrent/tap']});
  assert.equal(fs.readFileSync(f.journal, 'utf8'), 'example/php/php\n');
});
