#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

version=${PHP_VERSION:?}
channel=${CHANNEL:?}
php_darwin_validate_channel "$version" "$channel"
case "${FORCE:-false}:${PUBLISH:-false}" in
  true:*|false:false)
    printf 'build-required=true\n' >> "${GITHUB_OUTPUT:?}"
    printf 'Building explicitly requested PHP %s matrix\n' "$version"
    exit 0
    ;;
  false:true) ;;
  *) php_darwin_die 'invalid freshness control options' ;;
esac

work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-freshness.XXXXXX") || exit 1
trap 'rm -rf "$work_dir"' EXIT
manifest="$work_dir/manifest.json"
if [ -n "${PHP_DARWIN_MANIFEST_PATH:-}" ]; then
  cp "$PHP_DARWIN_MANIFEST_PATH" "$manifest" || exit 1
  status=200
else
  status=$(php_darwin_fetch_release_manifest "$(php_darwin_package_config release_repository)" "$version" "$manifest") || exit 1
fi
required=true
case "$status" in
  200)
    if php_darwin_validate_release_manifest "$manifest" "$version" "$channel" 2>/dev/null && \
      php_darwin_release_manifest_has_current_platforms "$manifest"; then
      current=$(bash "$script_dir/../lib/source-hash.sh" "$version") || exit 1
      current_extensions=$(bash "$script_dir/extensions-source-hash.sh" "$version") || exit 1
      published=$(jq -er '.source_hash' "$manifest") || exit 1
      published_extensions=$(bash "$script_dir/manifest-extensions-source-hash.sh" "$manifest" "$version") || exit 1
      php_current=$(bash "$script_dir/build-inputs-current.sh" "$manifest" "$version" php "$current" "$published") || exit 1
      extensions_current=$(bash "$script_dir/build-inputs-current.sh" "$manifest" "$version" extensions "$current_extensions" "$published_extensions") || exit 1
      if [ "$channel" = nightly ]; then
        current_commit=$(bash "$script_dir/php-src-commit.sh" "$version") || exit 1
        [ "$(jq -r '.php_src_commit' "$manifest")" = "$current_commit" ] || php_current=false
      fi
      dependencies_current=$("${PHP_DARWIN_NODE:-node}" "$script_dir/package-inputs.cjs" current "$manifest") || exit 1
      if [ "$php_current" = true ] && [ "$extensions_current" = true ] && [ "$dependencies_current" = true ]; then required=false; fi
    fi
    ;;
  404) ;;
  *) php_darwin_die "could not recheck published cache (HTTP $status)" ;;
esac
printf 'build-required=%s\n' "$required" >> "${GITHUB_OUTPUT:?}"
if [ "$required" = false ]; then
  printf 'PHP %s is already published with the requested inputs; skipping duplicate queued work\n' "$version"
else
  printf 'PHP %s needs a cache build\n' "$version"
fi
