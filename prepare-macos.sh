#!/usr/bin/env bash
set -euo pipefail
mkdir -p diagnostics
for origin in https://github.com/shivammathur/php-darwin/releases/download/php-8.5 https://artifacts.php-darwin.setup-php.com/php-8.5; do
  curl -fLSs --retry 3 "$origin/php-8.5-manifest.json" -o diagnostics/published-manifest.json
  jq -S '{php_semver,assets:[.assets[]|{name,sha256,bytes,download}]}' diagnostics/published-manifest.json > diagnostics/published-identity.json
  cmp expected-release.json diagnostics/published-identity.json
 done
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
formulae=()
while IFS= read -r item; do
  if [[ "$item" =~ ^php(@[0-9.]+)?(-debug)?(-zts)?$ || "$item" = swoole@8.5 ]]; then formulae+=("$item"); fi
done < <(brew list --formula)
if [ "${#formulae[@]}" -gt 0 ]; then brew uninstall --formula --force --ignore-dependencies "${formulae[@]}"; fi
rm -f /tmp/php8.5_extensions /tmp/abstract_patch
