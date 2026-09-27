#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-extensions-hash-test.XXXXXX") || \
  php_darwin_die 'could not create extension source hash fixtures'
fixture_root="$work_dir/root"
tap_path="$work_dir/homebrew-extensions"
manifest="$work_dir/manifest.json"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$fixture_root/conf/cached-extensions" "$tap_path/Abstract" "$tap_path/Formula" || \
  php_darwin_die 'could not create extension source hash fixture directories'
cp "$script_dir/../../../conf/versions" "$fixture_root/conf/versions" || \
  php_darwin_die 'could not copy the version fixture'
printf 'alpha\nbeta\n' > "$fixture_root/conf/cached-extensions/8.5" || \
  php_darwin_die 'could not write the cached extension fixture'
printf 'beta\n' > "$fixture_root/conf/zend-extensions" || \
  php_darwin_die 'could not write the Zend extension fixture'
printf 'shared source\n' > "$tap_path/Abstract/abstract-php-extension.rb" || \
  php_darwin_die 'could not write the shared extension fixture'
printf 'alpha source\n' > "$tap_path/Formula/alpha@8.5.rb" || \
  php_darwin_die 'could not write the alpha fixture'
printf 'beta source\n' > "$tap_path/Formula/beta@8.5.rb" || \
  php_darwin_die 'could not write the beta fixture'
printf 'unrelated source\n' > "$tap_path/Formula/unrelated@8.5.rb" || \
  php_darwin_die 'could not write the unrelated fixture'

initial=$(PHP_DARWIN_ROOT="$fixture_root" HOMEBREW_EXTENSIONS_PATH="$tap_path" \
  bash "$script_dir/../../build/extensions-source-hash.sh" 8.5) || \
  php_darwin_die 'could not hash the configured extension fixtures'
# Loading directives are part of the cache identity, even when source is unchanged.
: > "$fixture_root/conf/zend-extensions"
ordinary=$(PHP_DARWIN_ROOT="$fixture_root" HOMEBREW_EXTENSIONS_PATH="$tap_path" \
  bash "$script_dir/../../build/extensions-source-hash.sh" 8.5) || \
  php_darwin_die 'could not hash an ordinary extension configuration'
[ "$ordinary" != "$initial" ] || php_darwin_die 'changing a loading directive did not invalidate the extension hash'
printf 'beta\n' > "$fixture_root/conf/zend-extensions"

printf 'changed unrelated source\n' > "$tap_path/Formula/unrelated@8.5.rb" || \
  php_darwin_die 'could not change the unrelated fixture'
unrelated=$(PHP_DARWIN_ROOT="$fixture_root" HOMEBREW_EXTENSIONS_PATH="$tap_path" \
  bash "$script_dir/../../build/extensions-source-hash.sh" 8.5) || \
  php_darwin_die 'could not rehash the unrelated extension fixture'
[ "$unrelated" = "$initial" ] || php_darwin_die 'an unconfigured extension changed the cache source hash'

git -C "$tap_path" init -q || php_darwin_die 'could not initialize the extension source fixture'
git -C "$tap_path" config user.name php-darwin || php_darwin_die 'could not configure the fixture author'
git -C "$tap_path" config user.email php-darwin@example.invalid || \
  php_darwin_die 'could not configure the fixture email'
git -C "$tap_path" add . || php_darwin_die 'could not stage the extension source fixture'
git -C "$tap_path" -c commit.gpgsign=false commit -qm initial || \
  php_darwin_die 'could not commit the extension source fixture'
initial_commit=$(git -C "$tap_path" rev-parse HEAD) || php_darwin_die 'could not read the fixture commit'
committed=$(PHP_DARWIN_ROOT="$fixture_root" HOMEBREW_EXTENSIONS_PATH="$tap_path" \
  HOMEBREW_EXTENSIONS_REF="$initial_commit" bash "$script_dir/../../build/extensions-source-hash.sh" 8.5) || \
  php_darwin_die 'could not hash a pinned extension source commit'
[ "$committed" = "$initial" ] || php_darwin_die 'pinned and working-tree extension hashes disagree'

printf 'changed alpha source\n' > "$tap_path/Formula/alpha@8.5.rb" || \
  php_darwin_die 'could not change the configured extension fixture'
changed=$(PHP_DARWIN_ROOT="$fixture_root" HOMEBREW_EXTENSIONS_PATH="$tap_path" \
  bash "$script_dir/../../build/extensions-source-hash.sh" 8.5) || \
  php_darwin_die 'could not hash the changed extension fixture'
[ "$changed" != "$initial" ] || php_darwin_die 'a configured extension did not change the cache source hash'

jq -cn --arg commit "$initial_commit" '{homebrew_extensions_commit:$commit}' > "$manifest" || \
  php_darwin_die 'could not write the legacy extension manifest fixture'
legacy=$(PHP_DARWIN_ROOT="$fixture_root" HOMEBREW_EXTENSIONS_PATH="$tap_path" \
  bash "$script_dir/../../build/manifest-extensions-source-hash.sh" "$manifest" 8.5) || \
  php_darwin_die 'could not resolve a legacy manifest extension hash'
[ "$legacy" = "$initial" ] || php_darwin_die 'legacy extension provenance resolved the wrong source hash'

printf 'alpha\nbeta\ngamma\n' > \
  "$fixture_root/conf/cached-extensions/8.5" || php_darwin_die 'could not extend the cached extension fixture'
printf 'gamma source\n' > "$tap_path/Formula/gamma@8.5.rb" || \
  php_darwin_die 'could not write the future cached extension fixture'
legacy=$(PHP_DARWIN_ROOT="$fixture_root" HOMEBREW_EXTENSIONS_PATH="$tap_path" \
  bash "$script_dir/../../build/manifest-extensions-source-hash.sh" "$manifest" 8.5) || \
  php_darwin_die 'could not resolve legacy provenance after adding a cached extension'
[ -z "$legacy" ] || \
  php_darwin_die 'legacy provenance claimed to contain a newly configured cached extension'

jq -cn --arg hash "$changed" '{extensions_source_hash:$hash}' > "$manifest" || \
  php_darwin_die 'could not write the current extension manifest fixture'
resolved=$(PHP_DARWIN_ROOT="$fixture_root" HOMEBREW_EXTENSIONS_PATH="$tap_path" \
  bash "$script_dir/../../build/manifest-extensions-source-hash.sh" "$manifest" 8.5) || \
  php_darwin_die 'could not resolve the current manifest extension hash'
[ "$resolved" = "$changed" ] || php_darwin_die 'current extension provenance resolved the wrong source hash'

printf 'Cached extension source hash validation passed\n'
