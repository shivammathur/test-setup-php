#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

version=${PHP_VERSION:-8.6}
force=${FORCE:-false}
manifest_override=${PHP_DARWIN_MANIFEST_PATH:-}
release_repository=$(php_darwin_package_config release_repository)
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-nightly-update.XXXXXX") || \
  php_darwin_die 'could not create the nightly update directory'
trap 'rm -rf "$work_dir"' EXIT
manifest="$work_dir/php-$version-manifest.json"

php_darwin_validate_channel "$version" nightly
case "$force" in true|false) ;; *) php_darwin_die "force must be true or false: $force" ;; esac
current=$(bash "$script_dir/../build/php-src-commit.sh" "$version") || \
  php_darwin_die "could not resolve the PHP $version source commit"
current_extensions=$(bash "$script_dir/../build/extensions-source-hash.sh" "$version") || \
  php_darwin_die "could not resolve the PHP $version cached extension source hash"
current_formula=$(bash "$script_dir/../lib/source-hash.sh" "$version") || \
  php_darwin_die "could not resolve the PHP $version formula source hash"
published=
published_extensions=
manifest_current_platforms=false
manifest_source_commit=
manifest_extension_commit=
extensions_current=false
formula_current=false
dependencies_current=false

if [ -n "$manifest_override" ]; then
  [ -f "$manifest_override" ] || php_darwin_die "nightly manifest not found: $manifest_override"
  cp "$manifest_override" "$manifest" || php_darwin_die 'could not copy the nightly manifest fixture'
  http_status=200
else
  if ! http_status=$(php_darwin_fetch_release_manifest "$release_repository" "$version" "$manifest"); then
    php_darwin_die "could not request the PHP $version release manifest"
  fi
fi

case "$http_status" in
  200)
    if php_darwin_validate_release_manifest "$manifest" "$version" nightly 2>/dev/null; then
      dependencies_current=$("${PHP_DARWIN_NODE:-node}" "$script_dir/../build/package-inputs.cjs" current "$manifest") || exit 1
      published=$(jq -er '.php_src_commit' "$manifest") || \
        php_darwin_die "could not read the PHP $version published source commit"
      published_extensions=$(bash "$script_dir/../build/manifest-extensions-source-hash.sh" "$manifest" "$version") || \
        php_darwin_die "could not read the PHP $version published cached extension source hash"
      if [ "$force" = false ] && [ "$published" = "$current" ]; then
        published_formula=$(jq -er '.source_hash' "$manifest") || exit 1
        formula_current=$(bash "$script_dir/../build/build-inputs-current.sh" "$manifest" "$version" php \
          "$current_formula" "$published_formula") || \
          php_darwin_die "could not compare PHP $version formula build inputs"
        extensions_current=$(bash "$script_dir/../build/build-inputs-current.sh" "$manifest" "$version" extensions \
          "$current_extensions" "$published_extensions") || \
          php_darwin_die "could not compare PHP $version extension build inputs"
      fi
      if php_darwin_release_manifest_has_current_platforms "$manifest"; then
        manifest_current_platforms=true
      else
        manifest_source_commit=$(jq -er '.homebrew_php_commit | select(type == "string" and test("^[0-9a-f]{40}$"))' \
          "$manifest") || php_darwin_die "could not read the PHP $version published homebrew-php commit"
        manifest_extension_commit=$(jq -er '.homebrew_extensions_commit | select(type == "string" and test("^[0-9a-f]{40}$"))' \
          "$manifest") || php_darwin_die "could not read the PHP $version published homebrew-extensions commit"
      fi
    fi
    ;;
  404) ;;
  *) php_darwin_die "could not fetch the PHP $version release manifest (HTTP $http_status)" ;;
esac

build=false
if [ "$force" = true ] || [ "$published" != "$current" ] || \
  [ "$formula_current" != true ] || [ "$extensions_current" != true ] || [ "$dependencies_current" != true ] || [ "$manifest_current_platforms" = false ]; then
  build=true
fi
architectures='arm64 x86_64'
pinned_extension_commit=
pinned_source_commit=
if [ "$force" = false ] && [ "$published" = "$current" ] && \
  [ "$formula_current" = true ] && [ "$extensions_current" = true ] && [ "$dependencies_current" = true ] && [ "$manifest_current_platforms" = false ] && \
  [ -n "$manifest_source_commit" ] && [ -n "$manifest_extension_commit" ]; then
  architectures=x86_64
  pinned_extension_commit=$manifest_extension_commit
  pinned_source_commit=$manifest_source_commit
  printf 'Completing PHP %s nightly with Intel caches while retaining current ARM caches\n' "$version"
fi
if [ "$build" = true ]; then
  if [ -n "$published" ]; then
    printf 'PHP %s nightly changed: php-src %s to %s; extensions %s to %s\n' \
      "$version" "$published" "$current" "${published_extensions:-missing}" "$current_extensions"
  else
    printf 'PHP %s nightly has no valid published source commit; current commit is %s\n' "$version" "$current"
  fi
else
  printf 'PHP %s nightly is current (php-src %s, extensions %s)\n' \
    "$version" "$current" "$current_extensions"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'architectures=%s\nbuild=%s\nhomebrew-extensions-commit=%s\nhomebrew-php-commit=%s\nphp-src-commit=%s\nphp-version=%s\n' \
    "$architectures" "$build" "$pinned_extension_commit" "$pinned_source_commit" "$current" "$version" \
    >> "$GITHUB_OUTPUT" || \
    php_darwin_die 'could not write nightly freshness outputs'
fi
