#!/usr/bin/env bash
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || exit 1
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
node=${PHP_DARWIN_NODE:-node}
formula=icu4c@78
brew tap --force homebrew/core
brew install --formula "$formula" pkgconf
icu=$(brew --prefix "$formula")
test -f "$icu/lib/pkgconfig/icu-uc.pc"
backup="${RUNNER_TEMP:?}/icu-uc.pc"
cp "$icu/lib/pkgconfig/icu-uc.pc" "$backup"
# Simulate the observed hosted-runner state: a current keg and receipt with
# missing development metadata. The cache must pour a bottle, never compile.
rm "$icu/lib/pkgconfig/icu-uc.pc"
trap 'test -f "$icu/lib/pkgconfig/icu-uc.pc" || cp "$backup" "$icu/lib/pkgconfig/icu-uc.pc"' EXIT
"$node" <<'JS'
const assert = require('node:assert/strict');
const {install, brewSource} = require('./scripts/cache/source-bottle-cache.cjs');
(async () => {
  const [record] = JSON.parse(brewSource('info', ['plan', '["icu4c@78"]', 'false']));
  assert.equal(record.installed, false);
  assert.ok(record.missing_build_files.includes('lib/pkgconfig/icu-uc.pc'));
  const result = await install({formula: 'icu4c@78', cache: {
    restoreCache() { throw new Error('ICU test unexpectedly entered the source cache'); },
  }});
  assert.equal(result.built, 0);
  const [healthy] = JSON.parse(brewSource('info', ['plan', '["icu4c@78"]', 'false']));
  assert.equal(healthy.installed, true);
  assert.deepEqual(healthy.missing_build_files, []);
  await install({formula: 'icu4c@78', cache: {}, run() { throw new Error('Healthy ICU was reinstalled'); }});
})().catch(error => {console.error(error); process.exitCode = 1;});
JS
PKG_CONFIG_PATH="$icu/lib/pkgconfig" pkg-config --exists 'icu-uc >= 57.1' icu-i18n
printf 'Incomplete ICU restored from a bottle; healthy ICU retained\n'
