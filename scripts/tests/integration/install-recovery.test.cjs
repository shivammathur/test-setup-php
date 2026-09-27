const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {test} = require('node:test');
const installer = path.resolve(__dirname, '../../installer');

function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'php-darwin-recovery-')));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const prefix = path.join(root, 'prefix'), journal = path.join(root, 'commands.json'), links = path.join(root, 'links');
  fs.mkdirSync(path.join(prefix, 'bin'), {recursive: true});
  fs.writeFileSync(links, 'bin/php\t../Cellar/php@8.5/8.5.0/bin/php\nbin/php-config\t../Cellar/php@8.5/8.5.0/bin/php-config\n');
  const run = mode => spawnSync('bash', [path.join(installer, 'php-command-links.sh'), mode, prefix, journal, links, 'php@8.5'], {encoding: 'utf8'});
  return {root, prefix, journal, links, run};
}

test('stale PHP links without Homebrew records are replaced by extraction and restored on failure', t => {
  const f = fixture(t), target = path.join(f.prefix, 'bin/php');
  const old = '../Cellar/php/8.4.0/bin/php', replacement = '../Cellar/php@8.5/8.5.0/bin/php';
  fs.symlinkSync(old, target);
  assert.equal(f.run('prepare').status, 0);
  assert.throws(() => fs.lstatSync(target), /ENOENT/);
  // The actual archive/extractor supplies the default link.
  const staging = path.join(f.root, 'staging'); fs.mkdirSync(path.join(staging, 'bin'), {recursive: true});
  fs.symlinkSync(replacement, path.join(staging, 'bin/php'));
  const archive = path.join(f.root, 'fixture.tar'), exclusions = path.join(f.root, 'exclude');
  fs.writeFileSync(exclusions, '');
  assert.equal(spawnSync('tar', ['-cf', archive, '-C', staging, 'bin/php']).status, 0);
  const extracted = spawnSync('bash', [path.join(installer, 'extract.sh'), archive, f.prefix, exclusions], {encoding: 'utf8'});
  assert.equal(extracted.status, 0, extracted.stderr);
  assert.equal(fs.readlinkSync(target), replacement);
  assert.equal(f.run('restore').status, 0);
  assert.equal(fs.readlinkSync(target), old);
});

test('unmanaged command conflicts fail before unlinking any managed command', t => {
  const f = fixture(t);
  fs.symlinkSync('../opt/php/bin/php', path.join(f.prefix, 'bin/php'));
  fs.writeFileSync(path.join(f.prefix, 'bin/php-config'), 'user file');
  assert.equal(f.run('prepare').status, 1);
  assert.equal(fs.readlinkSync(path.join(f.prefix, 'bin/php')), '../opt/php/bin/php');
  assert.equal(fs.readFileSync(path.join(f.prefix, 'bin/php-config'), 'utf8'), 'user file');
  assert.equal(fs.existsSync(f.journal), false);
});

test('failed rollback retains the only keg backup and transaction diagnostics', t => {
  const f = fixture(t), transaction = path.join(f.root, 'transaction');
  fs.mkdirSync(path.join(transaction, 'target-keg-backup'), {recursive: true});
  fs.writeFileSync(path.join(transaction, 'target-keg-backup/user-state'), 'original');
  const source = fs.readFileSync(path.join(installer, 'install-package.sh'), 'utf8');
  const cleanup = source.slice(source.indexOf('php_darwin_install_cleanup() {'), source.indexOf('\ntrap php_darwin_install_cleanup EXIT'));
  const result = spawnSync('bash', ['-c', `
    tmp_dir=$1; brew_prefix=$2; script_dir=$3
    runtime_verified=false; preserve_tmp_dir=false; target_keg_backed_up=true
    target_keg_relative=Cellar/php/1; target_keg_backup="$tmp_dir/target-keg-backup"
    tap_installed=false; tap_path_backed_up=false; tap_snapshot_extracted=false; tap_snapshot_backed_up=false
    archive_mutation_started=false; pear_backed_up=false; pear_restored=true
    command_links_journal="$tmp_dir/commands.json"; unlink_journal_dir="$tmp_dir/unlinked"
    linked_php_references=(); linked_dependency_references=()
    php_darwin_reap_job() { :; }; php_darwin_restore_formula_trust() { :; }
    mv() { printf 'injected restoration failure\\n' >&2; return 1; }
    ${cleanup}
    false
    php_darwin_install_cleanup
  `, 'test', transaction, f.prefix, installer], {encoding: 'utf8'});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /rollback failed/);
  assert.match(result.stderr, /preserved recovery files/);
  assert.equal(fs.readFileSync(path.join(transaction, 'target-keg-backup/user-state'), 'utf8'), 'original');
  assert.match(fs.readFileSync(path.join(transaction, 'rollback.log'), 'utf8'), /injected restoration failure/);
});

test('PEAR restoration preserves custom settings while rejecting malformed archive defaults', t => {
  const f = fixture(t), source = fs.readFileSync(path.join(installer, 'install-package.sh'), 'utf8');
  const start = source.indexOf('PHP_DARWIN_PHASE=homebrew.configure');
  const configure = source.slice(start, source.indexOf('PHP_DARWIN_PHASE=homebrew.link', start));
  const config = 'etc/php/8.5/pear.conf', backup = path.join(f.root, 'postinstall-backup');
  const pear = path.join(f.prefix, config), defaults = `${f.prefix}/share/pear@8.5\n${f.prefix}/lib/php/pecl/20250925\n`;
  fs.mkdirSync(path.dirname(pear), {recursive: true});
  fs.mkdirSync(path.join(f.prefix, 'share/pear@8.5'), {recursive: true});
  fs.mkdirSync(path.join(f.prefix, 'opt/php@8.5'), {recursive: true});
  fs.symlinkSync('../../lib/php/pecl/20250925', path.join(f.prefix, 'opt/php@8.5/pecl'));
  fs.mkdirSync(path.join(backup, path.dirname(config)), {recursive: true});
  fs.writeFileSync(path.join(f.root, 'paths'), `${config}\n`);
  const run = () => spawnSync('bash', ['-c', `
    brew_prefix=$1; postinstall_backup_dir=$2; postinstall_paths_file=$3; postinstall_restored_file=$4
    pear_path=share/pear@8.5; pear_backed_up=false; config_id=8.5; pecl_extension=20250925; formula=php@8.5
    : > "$postinstall_restored_file"
    php_darwin_die() { echo "$*" >&2; exit 1; }
    ${configure}
  `, 'test', f.prefix, backup, path.join(f.root, 'paths'), path.join(f.root, 'restored')], {encoding: 'utf8'});
  fs.writeFileSync(pear, defaults);
  fs.writeFileSync(path.join(backup, config), '/custom/pear/settings\n');
  let result = run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(pear, 'utf8'), '/custom/pear/settings\n');
  // No prior file now exists: the same non-default data must fail validation.
  result = run();
  assert.equal(result.status, 1);
  assert.match(result.stderr, /wrong shared path/);
  fs.writeFileSync(pear, `${f.prefix}/share/pear@8.5\n/wrong/extensions\n`);
  assert.match(run().stderr, /wrong extension path/);
  fs.writeFileSync(pear, defaults);
  result = run();
  assert.equal(result.status, 0, result.stderr);
});
