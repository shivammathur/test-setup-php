#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

fixture_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-validation.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT
runtime_dependencies="$fixture_dir/runtime-dependencies.txt"
installed_formulae="$fixture_dir/installed-formulae.txt"
selected_formulae="$fixture_dir/selected-formulae.txt"
cleanup_formulae="$fixture_dir/cleanup-formulae.txt"
dependency_info="$fixture_dir/dependency-info.json"
php_dependencies="$fixture_dir/php-dependencies.txt"
unrelated_formulae="$fixture_dir/unrelated-formulae.txt"
printf '%s\n' 'dependency-new 1.0' 'hello 1.0' 'php-debug 8.5.10' \
  'updated-dependency 2.0' 'zstd 1.5.7' > "$installed_formulae"
printf '%s\n' dependency-new updated-dependency zstd > "$runtime_dependencies"
bash "$script_dir/../../build/select-packages.sh" "$runtime_dependencies" "$installed_formulae" php-debug "$selected_formulae" || \
  php_darwin_die 'runtime dependency package selection failed'
[ "$(tr '\n' ' ' < "$selected_formulae")" = 'dependency-new php-debug updated-dependency ' ] || \
  php_darwin_die 'runtime dependency package selection was incomplete'
printf '%s\n' dependency-new missing-dependency > "$runtime_dependencies"
if bash "$script_dir/../../build/select-packages.sh" "$runtime_dependencies" "$installed_formulae" php-debug \
  "$selected_formulae" 2>/dev/null; then
  php_darwin_die 'runtime dependency package selection accepted a missing dependency'
fi

printf '%s\n' \
  '{"formulae":[{"name":"zstd","full_name":"zstd"},{"name":"oniguruma","full_name":"oniguruma"},{"name":"openssl@3","full_name":"openssl@3"},{"name":"jq","full_name":"jq"},{"name":"icu4c@78","full_name":"icu4c@78"},{"name":"autoconf@2.69","full_name":"shivammathur/php/autoconf@2.69"}]}' \
  > "$dependency_info"
bash "$script_dir/../../build/canonicalize-formulae.sh" < "$dependency_info" > "$php_dependencies" || \
  php_darwin_die 'Homebrew dependency canonicalization failed'
[ "$(tr '\n' ' ' < "$php_dependencies")" = \
  'autoconf@2.69 icu4c@78 jq oniguruma openssl@3 zstd ' ] || \
  php_darwin_die 'Homebrew dependency canonicalization did not use canonical formula names'
printf '%s\n' 'autoconf@2.69 2.69' 'cmake 4.1.1' 'icu4c@77 77.1' 'icu4c@78 78.1' \
  'jq 1.8.1' 'oniguruma 6.9.10' 'openssl@3 3.5.2' 'php@8.4 8.4.13' 'zstd 1.5.7' \
  > "$cleanup_formulae"
bash "$script_dir/../../build/select-cleanup-formulae.sh" "$cleanup_formulae" "$php_dependencies" \
  "$unrelated_formulae" || php_darwin_die 'Homebrew cleanup selection failed'
[ "$(tr '\n' ' ' < "$unrelated_formulae")" = 'cmake icu4c@77 php@8.4 ' ] || \
  php_darwin_die 'Homebrew cleanup selection did not preserve the exact PHP dependencies'


printf 'package-selection validation passed\n'
