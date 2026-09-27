#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

only_version=${ONLY_VERSION:-}
release_repository=$(php_darwin_package_config release_repository)
workflow_repository=${GITHUB_REPOSITORY:-shivammathur/php-darwin}
workflow_ref=${GITHUB_REF_NAME:-main}
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-update.XXXXXX") || \
  php_darwin_die 'could not create the release update directory'
trap 'rm -rf "$work_dir"' EXIT

active_runs=$(gh api --method GET \
  "repos/$workflow_repository/actions/workflows/cache-stable.yml/runs" \
  -f branch="$workflow_ref" -F per_page=100 \
  --jq '.workflow_runs[] | [.status,.display_title] | @tsv') || \
  php_darwin_die 'could not inspect active stable cache workflows'

if [ -n "$only_version" ]; then
  php_darwin_validate_channel "$only_version" stable
  version_values=("$only_version")
else
  version_values=()
  configured_versions=$(php_darwin_configured_versions) || \
    php_darwin_die 'could not read the configured PHP versions'
  while read -r channel version; do
    [ "$channel" = stable ] && version_values+=("$version")
  done <<< "$configured_versions"
  [ "${#version_values[@]}" -gt 0 ] || php_darwin_die 'no stable PHP versions are configured'
fi

for version in "${version_values[@]}"; do
  current=$(bash "$script_dir/../lib/source-hash.sh" "$version") || \
    php_darwin_die "could not compute the PHP $version source hash"
  current_extensions=$(bash "$script_dir/../build/extensions-source-hash.sh" "$version") || \
    php_darwin_die "could not compute the PHP $version cached extension source hash"
  manifest="$work_dir/php-$version-manifest.json"
  published=
  published_extensions=
  manifest_current_platforms=false
  manifest_source_commit=
  manifest_extension_commit=
  php_current=false
  extensions_current=false
  dependencies_current=false
  if ! http_status=$(php_darwin_fetch_release_manifest "$release_repository" "$version" "$manifest"); then
    php_darwin_die "could not request the PHP $version release manifest"
  fi
  case "$http_status" in
    200)
      if php_darwin_validate_release_manifest "$manifest" "$version" stable 2>/dev/null; then
        dependencies_current=$("${PHP_DARWIN_NODE:-node}" "$script_dir/../build/package-inputs.cjs" current "$manifest") || exit 1
        published=$(jq -er '.source_hash' "$manifest") || \
          php_darwin_die "could not read the PHP $version published source hash"
        published_extensions=$(bash "$script_dir/../build/manifest-extensions-source-hash.sh" "$manifest" "$version") || \
          php_darwin_die "could not read the PHP $version published cached extension source hash"
        php_current=$(bash "$script_dir/../build/build-inputs-current.sh" "$manifest" "$version" php "$current" "$published") || \
          php_darwin_die "could not compare PHP $version build inputs"
        extensions_current=$(bash "$script_dir/../build/build-inputs-current.sh" "$manifest" "$version" extensions \
          "$current_extensions" "$published_extensions") || \
          php_darwin_die "could not compare PHP $version extension build inputs"
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
  if [ "$php_current" = true ] && [ "$extensions_current" = true ] && \
    [ "$manifest_current_platforms" = true ] && [ "$dependencies_current" = true ]; then
    printf 'PHP %s cache build inputs are current (PHP %s, extensions %s)\n' "$version" "$current" "$current_extensions"
    continue
  fi

  architectures='arm64 x86_64'
  pinned_arguments=()
  if [ "$php_current" = true ] && [ "$extensions_current" = true ] && \
    [ "$manifest_current_platforms" = false ] && [ "$dependencies_current" = true ] && [ -n "$manifest_source_commit" ] && \
    [ -n "$manifest_extension_commit" ]; then
    architectures=x86_64
    pinned_arguments=(-f "homebrew-php-commit=$manifest_source_commit" \
      -f "homebrew-extensions-commit=$manifest_extension_commit")
    printf 'Completing PHP %s with Intel caches while retaining current ARM caches\n' "$version"
  fi
  if [ -n "$published" ]; then
    printf 'Dispatching PHP %s: published PHP source %s, current PHP source %s; published extensions %s, current extensions %s\n' \
      "$version" "$published" "$current" "${published_extensions:-missing}" "$current_extensions"
  else
    printf 'Dispatching PHP %s: no valid release manifest, current source %s\n' "$version" "$current"
  fi
  if awk -F '\t' -v title="Cache stable PHP $version" \
    '$1 != "completed" && $2 == title { found=1 } END { exit !found }' <<< "$active_runs"; then
    printf 'PHP %s already has an active cache workflow; skipping duplicate dispatch\n' "$version"
    continue
  fi
  gh workflow run cache-stable.yml --repo "$workflow_repository" \
    --ref "$workflow_ref" -f php-version="$version" -f builds='debug release' \
    -f ts='nts zts' -f architectures="$architectures" "${pinned_arguments[@]}" -f publish=true || exit 1
done
