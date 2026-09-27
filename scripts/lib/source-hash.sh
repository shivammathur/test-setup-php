#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/lib.sh"

version=${1:?}
tap_path=${HOMEBREW_PHP_PATH:-}
php_darwin_validate_version "$version"
repository=$(php_darwin_package_config tap_repository)
branch=$(php_darwin_package_config tap_branch)
tmp_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-source.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
hashes="$tmp_dir/formulae.tsv"

while read -r build ts; do
  formula=$(php_darwin_formula "$version" "$build" "$ts") || exit 1
  formula_file="$tmp_dir/$formula.rb"
  if [ -n "$tap_path" ]; then
    cp "$tap_path/Formula/$formula.rb" "$formula_file" || php_darwin_die "could not read $formula from the local tap"
  else
    curl --retry 2 --retry-all-errors -fsSL \
      "${repository/github.com/raw.githubusercontent.com}/$branch/Formula/$formula.rb" \
      -o "$formula_file" || php_darwin_die "could not download $formula"
  fi
  formula_hash=$(php_darwin_sha256 "$formula_file") || php_darwin_die "could not hash $formula"
  printf '%s\t%s\n' "$formula" "$formula_hash" >> "$hashes" || php_darwin_die 'could not record a formula hash'
done < <(php_darwin_configured_variants)

LC_ALL=C sort -u "$hashes" -o "$hashes" || php_darwin_die 'could not sort formula hashes'
php_darwin_sha256 "$hashes" || php_darwin_die 'could not hash formula metadata'
