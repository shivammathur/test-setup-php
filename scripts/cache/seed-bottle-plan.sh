#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_VERBOSE=1 HOMEBREW_VERBOSE_USING_DOTS=0
export PATH="$script_dir:$PATH"
roots_file=${RUNNER_TEMP:-/tmp}/php-darwin-bottle-roots.txt
printf '%s\n' jq zstd > "$roots_file"
while read -r channel version; do
  while read -r build ts; do
    printf '%s/%s\n' "$(php_darwin_package_config tap)" \
      "$(php_darwin_requested_formula "$version" "$build" "$ts")" >> "$roots_file"
  done < <(php_darwin_configured_variants)
  while read -r extension; do
    printf '%s/%s@%s\n' "$(php_darwin_package_config extension_tap)" "$extension" "$version" >> "$roots_file"
  done < <(bash "$script_dir/../build/cached-extensions.sh" "$version")
done < <(php_darwin_configured_versions)
roots=$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "$roots_file")
# Ignore installed state and include root build dependencies, even where a PHP
# release bottle exists. This covers source/debug/ZTS and transitive source builds.
brew php-darwin-source info seed "$roots" true > bottle-plan.json
jq -c '.[] | select(.bottle != null) | .bottle | del(.cached_download)' bottle-plan.json > bottles.jsonl
jq -r '.[] | select(.bottled == false) | "Source-cache required: \(.full_name) \(.version)"' bottle-plan.json
printf 'Resolved %s roots; %s bottled dependencies\n' "$(jq length <<< "$roots")" "$(wc -l < bottles.jsonl)"
