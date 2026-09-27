#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

pinned_source_output=$(GITHUB_OUTPUT='' PINNED_COMMIT=0123456789abcdef0123456789abcdef01234567 \
  bash "$script_dir/../../build/source-commit.sh") || php_darwin_die 'pinned source commit validation failed'
[ "$pinned_source_output" = 0123456789abcdef0123456789abcdef01234567 ] || \
  php_darwin_die 'pinned source commit was not preserved'
if GITHUB_OUTPUT='' PINNED_COMMIT=invalid bash "$script_dir/../../build/source-commit.sh" >/dev/null 2>&1; then
  php_darwin_die 'invalid pinned source commit was accepted'
fi
approved_core=$(node "$script_dir/../../cache/approved-dependencies.cjs" core)
[ "$(GITHUB_OUTPUT='' PINNED_COMMIT='' PHP_DARWIN_UPDATE_DEPENDENCIES=false \
  bash "$script_dir/../../build/source-commit.sh" core)" = "$approved_core" ] || \
  php_darwin_die 'normal cache jobs did not retain the approved dependency snapshot'

for json_file in "$script_dir"/../../../conf/*.json "$script_dir"/../../../templates/*.json; do
  jq -e . "$json_file" >/dev/null || php_darwin_die "invalid JSON: $json_file"
done

current_version=$(php_darwin_package_config current_version)
php_darwin_validate_channel "$current_version" stable
php_darwin_validate_channel 5.6 stable
php_darwin_validate_channel 8.5 stable
php_darwin_validate_channel 8.6 nightly
php_darwin_validate_channel 8.7 nightly
php_darwin_validate_php_semver 8.6 8.6.0beta2 || \
  php_darwin_die 'nightly prerelease PHP version validation failed'
php_darwin_validate_php_semver 8.6 8.6.0RC1 || \
  php_darwin_die 'nightly release-candidate PHP version validation failed'
if php_darwin_validate_php_semver 8.6 8.6.beta2; then
  php_darwin_die 'malformed nightly prerelease PHP version was accepted'
fi
[ "$(php_darwin_formula "$current_version" debug zts "$current_version")" = php-debug-zts ] || \
  php_darwin_die 'preloaded current-version formula resolution failed'

version_count=0
nightly_count=0
seen_versions=
while read -r channel version; do
  case " $seen_versions " in *" $version "*) php_darwin_die "duplicate PHP version: $version" ;; esac
  seen_versions="$seen_versions $version"
  php_darwin_validate_channel "$version" "$channel"
  bash "$script_dir/../../build/cached-extensions.sh" "$version" records >/dev/null || \
    php_darwin_die "invalid cached extensions for PHP $version"
  version_count=$((version_count + 1))
  [ "$channel" != nightly ] || nightly_count=$((nightly_count + 1))
  seen_variants=
  while read -r build ts; do
    case " $seen_variants " in *" $build/$ts "*) php_darwin_die "duplicate variant: $build/$ts" ;; esac
    seen_variants="$seen_variants $build/$ts"
    php_darwin_formula "$version" "$build" "$ts" >/dev/null
    php_darwin_requested_formula "$version" "$build" "$ts" >/dev/null
    php_darwin_asset "$version" "$build" "$ts" arm64 >/dev/null
    php_darwin_asset "$version" "$build" "$ts" x86_64 >/dev/null
  done < <(php_darwin_configured_variants)
done < <(php_darwin_configured_versions)
for extension_file in "$script_dir/../../../conf/cached-extensions/"*; do
  [ -f "$extension_file" ] || php_darwin_die "invalid cached-extension file: $extension_file"
  php_darwin_validate_version "${extension_file##*/}"
done
[ "$version_count" -gt 0 ] || php_darwin_die 'no PHP versions are configured'
[ "$nightly_count" -gt 0 ] || php_darwin_die 'no nightly PHP versions are configured'
configured_versions=$(php_darwin_configured_versions | awk '{print $2}' | jq -Rsc 'split("\n")[:-1] | sort') || \
  php_darwin_die 'could not read configured PHP versions'
[ "$(printf '%s\n' "$seen_variants" | awk '{ print NF }')" -eq 4 ] || \
  php_darwin_die 'expected four build variants'
for required_variant in release/nts release/zts debug/nts debug/zts; do
  case " $seen_variants " in *" $required_variant "*) ;; *) php_darwin_die "missing build variant: $required_variant" ;; esac
done

jq -e '
  (keys | sort) == ["arm64", "x86_64"] and
  .arm64.brew_prefix == "/opt/homebrew" and .x86_64.brew_prefix == "/usr/local" and
  all(.[];
    (.minimum_macos | type == "number" and floor == . and . > 0) and
    (.platform_key | type == "string" and length > 0) and
    (.build_runner | type == "string" and length > 0) and
    (.test_runners | type == "array" and length > 0 and length == (unique | length)) and
    all(.test_runners[]; type == "string" and length > 0) and
    (.build_runner as $runner | .test_runners | index($runner) != null)
  )
' "$script_dir/../../../conf/platforms.json" >/dev/null || php_darwin_die 'invalid platform configuration'
jq -e '
  keys == ["platforms", "purpose", "schema"] and .schema == 1 and
  .platforms == {"arm64": {"minimum_macos": 14}}
' "$script_dir/../../../conf/legacy-platforms.json" >/dev/null || \
  php_darwin_die 'invalid legacy manifest platform configuration'
[ "$(php_darwin_expected_asset_count)" -eq 8 ] || php_darwin_die 'expected eight architecture-specific release assets'
[ "$(php_darwin_normalize_arch x86_64)" = x86_64 ] || php_darwin_die 'x86_64 normalization failed'
[ "$(php_darwin_normalize_arch amd64)" = x86_64 ] || php_darwin_die 'amd64 normalization failed'

archive_roots=
while IFS= read -r root extra; do
  [ -n "$root" ] || continue
  case "$root" in \#*) continue ;; esac
  [ -z "$extra" ] || php_darwin_die "invalid archive root: $root $extra"
  case "$root" in Cellar|Frameworks|bin|etc|include|lib|opt|sbin|share|var) ;; *)
    php_darwin_die "unsafe archive root: $root"
    ;;
  esac
  case " $archive_roots " in *" $root "*) php_darwin_die "duplicate archive root: $root" ;; esac
  archive_roots="$archive_roots $root"
done < "$script_dir/../../../conf/archive-paths"
[ "$archive_roots" = ' Cellar Frameworks bin etc include lib opt sbin share var' ] || \
  php_darwin_die 'archive roots are incomplete or out of order'
snapshot_roots=$(awk '!/^#/ && NF { printf "%s%s", separator, $1; separator=" " }' \
  "$script_dir/../../../conf/snapshot-paths") || php_darwin_die 'could not read snapshot roots'
[ "$snapshot_roots" = 'etc var' ] || php_darwin_die 'snapshot roots must be etc and var'

jq -e --argjson versions "$configured_versions" '
  keys == ["compression_level", "compression_long", "max_archive_bytes"] and
  (.compression_level | type == "number" and . >= 1 and . <= 22 and . == floor) and
  .compression_level == 19 and .compression_long == 27 and
  (.max_archive_bytes | keys | sort) == $versions and
  all(.max_archive_bytes[]; . == 180000000)
' "$script_dir/../../../conf/build.json" >/dev/null || php_darwin_die 'invalid build configuration'
jq -e '
  keys == ["current_version", "extension_tap", "extension_tap_branch", "extension_tap_repository",
           "release_repository", "tap", "tap_branch", "tap_repository", "tap_snapshot"] and
  .release_repository == "shivammathur/php-darwin" and
  .extension_tap == "shivammathur/extensions" and .extension_tap_branch == "main" and
  .extension_tap_repository == "https://github.com/shivammathur/homebrew-extensions" and
  .tap == "shivammathur/php" and .tap_branch == "main" and
  .tap_repository == "https://github.com/shivammathur/homebrew-php" and
  .tap_snapshot == "var/php-darwin/homebrew-php"
' "$script_dir/../../../conf/package.json" >/dev/null || php_darwin_die 'invalid package configuration'
jq -e '
  keys == ["architecture", "archive", "brew_prefix", "build", "created_at", "extensions", "extensions_source_hash", "formula",
           "formula_sha256", "homebrew_extensions_commit", "homebrew_php_commit", "links",
           "macos_version", "minimum_macos", "packages",
           "pear_path", "pecl_extension", "php_semver", "php_src_commit", "php_version", "platform_key", "requested_formula",
           "runner_image", "schema", "source_hash", "state_paths", "tap_formulae", "tap_snapshot", "thread_safety"] and .schema == 1 and
  .extensions == [] and .extensions_source_hash == "" and .homebrew_extensions_commit == "" and
  .links == [] and .packages == [] and .state_paths == [] and .tap_formulae == [] and
  .pear_path == "" and .pecl_extension == "" and .php_src_commit == "" and
  .source_hash == "" and .tap_snapshot == ""
' "$script_dir/../../../templates/cache-metadata.json" >/dev/null || php_darwin_die 'invalid cache metadata template'
jq -e '
  keys == ["assets", "extensions_source_hash", "homebrew_extensions_commit", "homebrew_php_commit", "php_semver", "php_src_commit",
           "php_version", "schema", "source_hash"] and
  .schema == 1 and .assets == [] and .extensions_source_hash == "" and .homebrew_extensions_commit == "" and
  .homebrew_php_commit == "" and .php_semver == "" and
  .php_src_commit == "" and .php_version == "" and .source_hash == ""
' "$script_dir/../../../templates/release-manifest.json" >/dev/null || php_darwin_die 'invalid release manifest template'

[ "$(bash "$script_dir/../../build/cached-extensions.sh" 5.6 | tr '\n' ' ')" = 'xdebug ' ] || \
  php_darwin_die 'PHP 5.6 cached extensions are invalid'
[ "$(bash "$script_dir/../../build/cached-extensions.sh" 7.0 | tr '\n' ' ')" = 'xdebug ' ] || \
  php_darwin_die 'PHP 7.0 cached extensions are invalid'
[ "$(bash "$script_dir/../../build/cached-extensions.sh" 8.5 | tr '\n' ' ')" = 'xdebug pcov ' ] || \
  php_darwin_die 'PHP 8.5 cached extensions are invalid'
[ "$(bash "$script_dir/../../build/cached-extensions.sh" 8.6 | tr '\n' ' ')" = 'xdebug pcov ' ] || \
  php_darwin_die 'PHP 8.6 cached extensions are invalid'
[ "$(bash "$script_dir/../../build/cached-extensions.sh" 8.7 | tr '\n' ' ')" = 'xdebug pcov ' ] || \
  php_darwin_die 'PHP 8.7 cached extensions are invalid'
[ "$(bash "$script_dir/../../build/cached-extensions.sh" 8.5 records | tr '\n' ' ')" = \
  $'xdebug\tzend_extension pcov\textension ' ] || \
  php_darwin_die 'PHP 8.5 cached extension types are invalid'

[ "$(php_darwin_pear_path 8.5 php)" = 'share/pear' ] || php_darwin_die 'current PEAR path is invalid'
[ "$(php_darwin_pear_path 8.4 'php@8.4')" = 'share/pear@8.4' ] || \
  php_darwin_die 'versioned PEAR path is invalid'
[ "$(php_darwin_pear_path 8.4 'php@8.4-debug-zts')" = 'share/pear@8.4-debug-zts' ] || \
  php_darwin_die 'versioned variant PEAR path is invalid'
[ "$(php_darwin_config_id 8.5 debug zts)" = '8.5-debug-zts' ] || \
  php_darwin_die 'variant configuration id is invalid'
[ "$(php_darwin_metadata_path 'php_8.5-nts-release+darwin_arm64.tar.zst')" = \
  'var/php-darwin/php_8.5-nts-release+darwin_arm64.json' ] || php_darwin_die 'embedded metadata path is invalid'
current_postinstall_paths=$(php_darwin_postinstall_paths 8.5 php | tr '\n' ' ')
[ "$current_postinstall_paths" = 'etc/php/8.5/pear.conf ' ] || \
  php_darwin_die 'current post-install paths are invalid'
versioned_postinstall_paths=$(php_darwin_postinstall_paths 8.4 'php@8.4' | tr '\n' ' ')
[ "$versioned_postinstall_paths" = \
  'etc/php/8.4/pear.conf etc/php/8.4/conf.d/ext-intl.ini etc/php/8.4/conf.d/ext-opcache.ini ' ] || \
  php_darwin_die 'versioned post-install paths are invalid'
variant_postinstall_paths=$(php_darwin_postinstall_paths 8.4 'php@8.4-debug-zts' debug zts | tr '\n' ' ')
[ "$variant_postinstall_paths" = \
  'etc/php/8.4-debug-zts/pear.conf etc/php/8.4-debug-zts/conf.d/ext-intl.ini etc/php/8.4-debug-zts/conf.d/ext-opcache.ini ' ] || \
  php_darwin_die 'variant post-install paths are invalid'


printf 'configuration validation passed\n'
