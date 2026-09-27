const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '../../..');
const patcher = path.join(root, 'scripts/build/extension-formula.rb');
const ruby = process.env.PHP_DARWIN_RUBY || 'ruby';
const template = `class Extension
  def self.depends_on(formula, *); @dependency = formula; end
  def self.init(version)
    @php_version = version
    depends_on "shivammathur/php/php@#{@php_version}" => [:build, :test]
  end
  def php_formula
    "shivammathur/php/php@#{php_version}"
  end
  def config_scandir_path
    etc / "php" / php_version / "conf.d"
  end
  def safe_phpize
    puts ENV["ac_cv_prog_cc_c23"] || "default"
  end
  def self.dependency; @dependency.keys.first; end
end
Extension.init(ARGV[0])
puts Extension.new.php_formula
puts Extension.dependency
Extension.new.safe_phpize
`;

test('extension builds resolve the actual PHP formula for current, versioned and nightly variants', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-formula-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const file = path.join(directory, 'abstract.rb');
  const current = require('../../../conf/package.json').current_version;
  for (const version of require('../../../conf/extension-packs.json').versions) {
    for (const suffix of ['', '-debug', '-zts', '-debug-zts']) {
      const formula = (version === current ? 'php' : `php@${version}`) + suffix;
      fs.writeFileSync(file, template);
      execFileSync(ruby, [patcher, file, formula, version + suffix, version], { stdio: 'pipe' });
      const output = execFileSync(ruby, [file, version], { encoding: 'utf8', stdio: 'pipe', env: { ...process.env, ac_cv_prog_cc_c23: '' } }).trim().split('\n');
      assert.deepEqual(output.slice(0, 2), Array(2).fill('shivammathur/php/' + formula));
      assert.equal(output[2] || '', /^(5|7)\./.test(version) ? 'no' : '');
      assert.ok(fs.readFileSync(file, 'utf8').includes(`etc / "php" / "${version + suffix}" / "conf.d"`));
    }
  }
  fs.writeFileSync(file, 'changed upstream template');
  assert.throws(() => execFileSync('ruby', [patcher, file, 'php', current, current], { stdio: 'pipe' }));
  assert.equal(fs.readFileSync(file, 'utf8'), 'changed upstream template');
});
