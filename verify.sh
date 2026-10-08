#!/usr/bin/env bash
set -euo pipefail
prefix=$(brew --prefix)
formula=$(jq -er .formula "$TEST_METADATA")
target=$(jq -er --arg formula "$formula" '.packages[] | select(.name==$formula) | .opt_target' "$TEST_METADATA")
receipt="$prefix/opt/$formula/INSTALL_RECEIPT.json"
[ "$(readlink "$prefix/opt/$formula")" = "$target" ]
while IFS= read -r alias; do
  [ "$(readlink "$prefix/opt/$alias")" = "$target" ]
  cmp "$prefix/opt/$alias/bin/phpize" "$prefix/opt/$formula/bin/phpize"
  cmp "$prefix/opt/$alias/bin/php-config" "$prefix/opt/$formula/bin/php-config"
  "$prefix/opt/$alias/bin/phpize" --version
  [ "$("$prefix/opt/$alias/bin/php-config" --version)" = 8.5.11 ]
  printf '%s -> %s\n' "$alias" "$(readlink "$prefix/opt/$alias")"
done < <(jq -er '.aliases[]' "$receipt") | tee diagnostics/aliases.txt
# Ensure the old extension path helper remains under test.
tap="$prefix/Library/Taps/shivammathur/homebrew-extensions"
[ -d "$tap" ] || tap="$(brew --repository)/Library/Taps/shivammathur/homebrew-extensions"
grep -F 'formula_opt_bin(php_formula)' "$tap/Abstract/abstract-php-extension.rb" > diagnostics/path-helper.txt
php -r 'if ((bool) PHP_DEBUG !== (getenv("EXPECTED_BUILD") === "debug")) exit(1);'
brew list --versions swoole@8.5 | tee diagnostics/brew-version.txt
binary="$(brew --prefix swoole@8.5)/swoole.so"
cmp "$binary" "$(php-config --extension-dir)/swoole.so"
file "$binary" | tee diagnostics/binary.txt
otool -L "$binary" | tee diagnostics/dependencies.txt
php smoke.php | tee diagnostics/smoke.txt
asset_sha=$(jq -er --arg asset "$TEST_ASSET" '.assets[] | select(.name==$asset) | .sha256' repaired/php-8.5-manifest.json)
[ "$(shasum -a 256 "repaired/${TEST_ASSET%.tar.zst}/$TEST_ASSET" | cut -d ' ' -f 1)" = "$asset_sha" ]
# The download log proves the tested installer fetched this artifact, and its
# checksum validation plus embedded metadata comparison completed successfully.
grep -F "$TEST_ASSET" "$RUNNER_TEMP/archive-server.log"
grep -F 'Installed PHP' "$RUNNER_TEMP/php-darwin-setup-install.log"
jq -n --slurpfile stage repaired/stage.json --arg job "$TEST_JOB" --arg asset "$TEST_ASSET" \
  --arg sha "$asset_sha" --arg version "$(php-config --version)" \
  '{stage:$stage[0],job:$job,asset:$asset,sha256:$sha,php_version:$version,aliases_verified:true,swoole_smoke:true,homebrew_binary_verified:true}' \
  > diagnostics/evidence.json
