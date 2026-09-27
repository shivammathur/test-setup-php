#!/usr/bin/env bash
set -euo pipefail

[ "${GITHUB_ACTIONS:-}" = true ] || { printf 'Native source cache tests require an Actions runner\n' >&2; exit 1; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
tap=php-darwin/source-cache-test
library="$tap/php-darwin-cache-lib"
app="$tap/php-darwin-cache-app"
tool="$tap/php-darwin-cache-tool@1"
fixtures="${GITHUB_WORKSPACE:?}/.source-cache-fixtures"

case "${1:?}" in
  prepare)
    mkdir -p "$fixtures"
    python3 - "$fixtures" <<'PY'
import gzip, io, pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1])
files = {
    'library.c': b'int cached_value(void) { return 42; }\n',
    'library.h': b'int cached_value(void);\n',
    'app.c': b'#include <stdio.h>\n#include "library.h"\nint main(void) { printf("%d\\n", cached_value()); return cached_value() != 42; }\n',
}
with gzip.GzipFile(filename=str(root/'source.tar.gz'), mode='wb', mtime=0) as gz:
    with tarfile.open(fileobj=gz, mode='w') as archive:
        for name, contents in sorted(files.items()):
            info = tarfile.TarInfo('source/' + name)
            info.size = len(contents)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(contents))
PY
    source_hash=$(shasum -a 256 "$fixtures/source.tar.gz" | awk '{print $1}')
    brew tap-new --no-git "$tap"
    tap_path=$(brew --repository "$tap")
    cat > "$tap_path/Formula/php-darwin-cache-lib.rb" <<EOF
class PhpDarwinCacheLib < Formula
  desc "Source bottle cache test library"
  homepage "https://github.com/shivammathur/php-darwin"
  url "file://$fixtures/source.tar.gz"
  version "1.0.0"
  sha256 "$source_hash"
  license "MIT"
  def install
    system ENV.cc, "-dynamiclib", "library.c", "-o", "libcachedvalue.dylib",
           "-install_name", "#{opt_lib}/libcachedvalue.dylib"
    lib.install "libcachedvalue.dylib"
    include.install "library.h"
    config = etc/"php-darwin-source-cache-test/library.conf"
    config.dirname.mkpath
    config.write "#{prefix}\\n" unless config.exist?
    inreplace config, prefix.to_s, opt_prefix.to_s, audit_result: build.bottle?
  end
end
EOF
    cat > "$tap_path/Formula/php-darwin-cache-tool@1.rb" <<EOF
class PhpDarwinCacheToolAT1 < Formula
  desc "Versioned build tool linking regression fixture"
  homepage "https://github.com/shivammathur/php-darwin"
  url "file://$fixtures/source.tar.gz"
  version "1.0.0"
  sha256 "$source_hash"
  license "MIT"
  keg_only :versioned_formula
  def install
    # The consumer owns this command in the global prefix. A dependency must
    # retain its private copy without taking the consumer's command name.
    (buildpath/"php-darwin-cache-app").write "#!/bin/sh\\necho dependency\\n"
    bin.install "php-darwin-cache-app"
    chmod 0755, bin/"php-darwin-cache-app"
  end
end
EOF
    cat > "$tap_path/Formula/php-darwin-cache-app.rb" <<EOF
class PhpDarwinCacheApp < Formula
  desc "Source bottle cache test consumer"
  homepage "https://github.com/shivammathur/php-darwin"
  url "file://$fixtures/source.tar.gz"
  version "1.0.0"
  sha256 "$source_hash"
  license "MIT"
  depends_on "$library"
  depends_on "$tool" => :build
  def install
    dependency = Formula["$library"]
    system ENV.cc, "app.c", "-I#{dependency.opt_include}", "-L#{dependency.opt_lib}",
           "-lcachedvalue", "-o", "php-darwin-cache-app"
    bin.install "php-darwin-cache-app"
  end
  if respond_to?(:post_install_steps)
    post_install_steps do
      mkdir_p "php-darwin-source-cache-test", base: :var
      write_file "php-darwin-source-cache-test/postinstall", "ready", base: :var
    end
  else
    def post_install
      (var/"php-darwin-source-cache-test").mkpath
      (var/"php-darwin-source-cache-test/postinstall").write "ready"
    end
  end
end
EOF
    cat > "$tap_path/Formula/php-darwin-cache-bottled.rb" <<EOF
class PhpDarwinCacheBottled < Formula
  desc "Bottle planning regression fixture"
  homepage "https://github.com/shivammathur/php-darwin"
  url "file://$fixtures/source.tar.gz"
  version "1.0.0"
  sha256 "$source_hash"
  license "MIT"
  bottle do
    root_url "file://$fixtures"
    sha256 Utils::Bottles.tag.to_sym => "$source_hash"
  end
  depends_on "$library" => :build
end
EOF
    brew trust "$tap"
    ;;
  verify-plan)
    # This fixture is never installed. Its platform-default Cellar must be
    # recognized without fetching anything or including its source build tool.
    "${PHP_DARWIN_NODE:-node}" <<'JS'
const assert = require('node:assert/strict');
const { brewSource } = require('./scripts/cache/source-bottle-cache.cjs');
const formula = 'php-darwin/source-cache-test/php-darwin-cache-bottled';
const plan = force => JSON.parse(brewSource('info', ['plan', JSON.stringify([formula]), String(force)]));
const bottled = plan(false);
assert.deepEqual(bottled.map(item => item.full_name), [formula]);
assert.equal(bottled[0].bottled, true);
assert.deepEqual(plan(true).map(item => item.name), ['php-darwin-cache-lib', 'php-darwin-cache-bottled']);
console.log('Native bottle selected; build-only dependency included only for forced source builds');
JS
    ;;
  verify-outdated)
    "${PHP_DARWIN_NODE:-node}" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { brewSource, command } = require('./scripts/cache/source-bottle-cache.cjs');
const formula = 'php-darwin/source-cache-test/php-darwin-cache-lib';
const recipe = path.join(command('brew', ['--repository', 'php-darwin/source-cache-test']).trim(),
  'Formula/php-darwin-cache-lib.rb');
const previous = fs.readFileSync(recipe, 'utf8');
const consumerRecipe = path.join(path.dirname(recipe), 'php-darwin-cache-bottled.rb');
const previousConsumer = fs.readFileSync(consumerRecipe, 'utf8');
const plan = () => JSON.parse(brewSource('info', ['plan', JSON.stringify([formula]), 'true'])).at(-1);
assert.equal(plan().installed, true);
try {
  fs.writeFileSync(recipe, previous.replace('version "1.0.0"', 'version "1.0.1"'));
  const updated = plan();
  assert.equal(updated.version, '1.0.1');
  assert.equal(updated.installed, false, 'an older installed keg suppressed the required update');
  fs.writeFileSync(consumerRecipe, previousConsumer.replace('depends_on "php-darwin/source-cache-test/php-darwin-cache-lib"',
    'depends_on "php-darwin/source-cache-test/php-darwin-cache-app"'));
  const toolPlan = JSON.parse(brewSource('info', ['plan',
    JSON.stringify(['php-darwin/source-cache-test/php-darwin-cache-bottled']), 'true']));
  assert.deepEqual(toolPlan.map(item => item.name), ['php-darwin-cache-app', 'php-darwin-cache-bottled'],
    'an installed build tool must not upgrade its unrelated runtime libraries');
} finally {
  fs.writeFileSync(recipe, previous);
  fs.writeFileSync(consumerRecipe, previousConsumer);
}
assert.equal(plan().installed, true);
console.log('Current dependency reused; older installed version correctly requires an update');
console.log('Installed build tool reused without rebuilding its runtime dependency tree');
JS
    ;;
  verify)
    [ "$("$(brew --prefix "$app")/bin/php-darwin-cache-app")" = 42 ]
    [ "$("$(brew --prefix)/bin/php-darwin-cache-app")" = 42 ]
    python3 - "$(brew --cellar)" <<'PY'
import json, pathlib, sys
cellar = pathlib.Path(sys.argv[1])
for name in ['php-darwin-cache-lib', 'php-darwin-cache-tool@1']:
    receipt = next((cellar/name).glob('*/INSTALL_RECEIPT.json'))
    assert json.loads(receipt.read_text())['installed_on_request'] is False, name
print('Versioned build tool stays private; dependency receipts are not direct requests')
PY
    [ "$(cat "$(brew --prefix)/var/php-darwin-source-cache-test/postinstall")" = ready ]
    brew linkage --test "$app" "$library"
    # Verify the actual native packages, not just cache status messages.
    while IFS= read -r -d '' bottle; do
      tar -tzf "$bottle" > "$fixtures/bottle-contents.txt"
      grep -q 'INSTALL_RECEIPT.json' "$fixtures/bottle-contents.txt"
      grep -q '/.brew/.*\.rb' "$fixtures/bottle-contents.txt"
    done < <(find .source-bottle-cache -name '*.tar.gz' -print0)
    ;;
  reset)
    brew uninstall --force --ignore-dependencies "$app" "$library" "$tool"
    rm -rf .source-bottle-cache
    rm -f "$(brew --prefix)/var/php-darwin-source-cache-test/postinstall"
    ;;
  bump)
    tap_path=$(brew --repository "$tap")
    sed -i '' 's/version "1.0.0"/version "1.0.1"/' "$tap_path/Formula/php-darwin-cache-app.rb"
    ;;
  verify-release)
    "${PHP_DARWIN_NODE:-node}" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { ReleaseCache, family, assetIdentity } = require('./scripts/cache/source-bottle-releases.cjs');
(async () => {
  const cache = new ReleaseCache({ tag: process.env.CACHE_RELEASE });
  const assets = await cache.assets(await cache.release());
  const entries = fs.readdirSync('.source-bottle-cache').map(key =>
    JSON.parse(fs.readFileSync(path.join('.source-bottle-cache', key, 'metadata.json'))));
  const app = entries.find(entry => entry.inputs.formula.endsWith('/php-darwin-cache-app'));
  assert.equal(app.inputs.version, '1.0.1');
  const versions = assets.map(assetIdentity).filter(identity => identity?.group === family(app.inputs))
    .map(identity => identity.version);
  assert.deepEqual(versions, ['1.0.1']);
  console.log('Release retains the new consumer and has removed its older version');
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
    ;;
  prepare-config-upgrade)
    # Reproduce an install audit such as OpenLDAP's with an older, customized
    # config already present. Keep the installed keg so its bottle owns it.
    tap_path=$(brew --repository "$tap")
    printf 'custom configuration\n' > "$(brew --prefix)/etc/php-darwin-source-cache-test/library.conf"
    sed -i '' 's/version "1.0.0"/version "1.0.1"/' "$tap_path/Formula/php-darwin-cache-lib.rb"
    ;;
  verify-config-upgrade)
    [ "$(cat "$(brew --prefix)/etc/php-darwin-source-cache-test/library.conf")" = 'custom configuration' ]
    [ -d "$(brew --cellar)/php-darwin-cache-lib/1.0.0" ]
    [ -d "$(brew --cellar)/php-darwin-cache-lib/1.0.1" ]
    python3 - <<'PY'
import json, pathlib, tarfile
for file in pathlib.Path('.source-bottle-cache').glob('*/metadata.json'):
    data = json.loads(file.read_text())
    if not data['inputs']['formula'].endswith('/php-darwin-cache-lib') or data['inputs']['version'] != '1.0.1':
        continue
    with tarfile.open(file.parent / data['file']) as archive:
        member = next(m for m in archive if m.name.endswith('/.bottle/etc/php-darwin-source-cache-test/library.conf'))
        contents = archive.extractfile(member).read()
        assert b'custom configuration' not in contents and b'/opt/php-darwin-cache-lib' in contents
    break
else:
    raise AssertionError('missing upgraded library bottle')
print('Native source upgrade preserved existing configuration and keg; bottle contains clean defaults')
PY
    "${PHP_DARWIN_NODE:-node}" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { install, command } = require('./scripts/cache/source-bottle-cache.cjs');
(async () => {
  const prefix = command('brew', ['--prefix']).trim();
  const opt = path.join(prefix, 'opt/php-darwin-cache-lib');
  const rack = path.join(prefix, 'Cellar/php-darwin-cache-lib');
  const cache = { async restoreCache() { throw new Error('Unexpected cache download'); },
    async saveCache() { throw new Error('Unexpected source build'); } };
  for (const previous of ['1.0.0', null]) {
    fs.unlinkSync(opt);
    if (previous) fs.symlinkSync(path.join(rack, previous), opt);
    const result = await install({ formula: 'php-darwin/source-cache-test/php-darwin-cache-lib', cache });
    assert.deepEqual(result, { built: 0, restored: 0 });
    assert.equal(fs.realpathSync(opt), path.join(rack, '1.0.1'));
    assert.ok(fs.statSync(path.join(rack, '1.0.0')).isDirectory());
    assert.equal(fs.readFileSync(path.join(prefix, 'etc/php-darwin-source-cache-test/library.conf'), 'utf8'), 'custom configuration\n');
  }
  console.log('Current installed keg selected from stale and missing opt links without removing old versions or changing configuration');
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
    ;;
  cleanup)
    if brew tap | grep -Fxq "$tap"; then
      brew uninstall --force --ignore-dependencies "$app" "$library" "$tool" || true
      HOMEBREW_DEVELOPER=1 brew untap "$tap" || true
    fi
    rm -rf "$(brew --prefix)/var/php-darwin-source-cache-test"
    rm -rf "$(brew --prefix)/etc/php-darwin-source-cache-test"
    ;;
  *) exit 1 ;;
esac
