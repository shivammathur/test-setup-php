#!/usr/bin/env bash
set -euo pipefail
mkdir diagnostics
asset="php_8.5-$EXPECTED_TS-$EXPECTED_BUILD+darwin_$(uname -m).tar.zst"
variant="repaired/${asset%.tar.zst}"
archive="$variant/$asset"
(cd "$variant" && shasum -a 256 -c "$asset.sha256")
cp "$variant/repair-report.json" diagnostics/
metadata="$variant/${asset%.tar.zst}.json"
formula=$(jq -er .formula "$metadata")
keg=$(jq -er --arg formula "$formula" '.packages[] | select(.name==$formula) | .opt_target | ltrimstr("../")' "$metadata")
alias=$(jq -er '.links[] | select(.path|startswith("opt/")) | .path' "$metadata")
# Validate the actual tar extraction, before the installer can fix any links.
mkdir "$RUNNER_TEMP/alias-extraction"
tar -xpf "$archive" -C "$RUNNER_TEMP/alias-extraction" "opt/$formula" "$alias" \
  "$keg/INSTALL_RECEIPT.json" "$keg/bin/phpize" "$keg/bin/php-config"
[ "$(readlink "$RUNNER_TEMP/alias-extraction/$alias")" = "../$keg" ]
[ "$(readlink "$RUNNER_TEMP/alias-extraction/opt/$formula")" = "../$keg" ]
cmp "$RUNNER_TEMP/alias-extraction/$alias/bin/phpize" "$RUNNER_TEMP/alias-extraction/$keg/bin/phpize"
# Ensure the action exercises the cold cache path on NTS as well as ZTS/debug.
formulae=()
while IFS= read -r item; do
  if [[ "$item" =~ ^php(@[0-9.]+)?(-debug)?(-zts)?$ || "$item" = swoole@8.5 ]]; then formulae+=("$item"); fi
done < <(brew list --formula)
if [ "${#formulae[@]}" -gt 0 ]; then brew uninstall --formula --force --ignore-dependencies "${formulae[@]}"; fi
rm -f /tmp/php8.5_extensions /tmp/abstract_patch
# The action is unchanged; only its release-download origin and installer are staged.
printf 'PHP_DARWIN_RELEASE_URL=http://127.0.0.1:8765/%s/%s\n' "${asset%.tar.zst}" "$asset" >> "$GITHUB_ENV"
printf 'TEST_ASSET=%s\nTEST_METADATA=%s\n' "$asset" "$GITHUB_WORKSPACE/$metadata" >> "$GITHUB_ENV"
