#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"
# shellcheck source=scripts/lib/retry.sh
. "$script_dir/../lib/retry.sh"
version=${PHP_VERSION:?}
php_darwin_validate_version "$version"
repo=$(php_darwin_package_config release_repository)
tag=php-$version
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-sync.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
manifest="$work_dir/$tag-manifest.json"
php_darwin_retry gh release download "$tag" --repo "$repo" --pattern "$tag-manifest.json" --clobber --dir "$work_dir"
php_darwin_validate_release_manifest "$manifest" "$version" >/dev/null
PHP_DARWIN_RELEASE_MANIFEST="$manifest" bash "$script_dir/../installer/generate-install.sh" "$work_dir/install.sh"
mirror=$(php_darwin_release_mirror "$repo" "$version")
mode=all
if php_darwin_retry curl -fsSL --retry 0 --connect-timeout 5 --max-time 30 "$mirror/$tag-manifest.json" -o "$work_dir/mirror-manifest" &&
  cmp -s "$manifest" "$work_dir/mirror-manifest"; then
  mode=installer-only
fi
if [ "$mode" = all ]; then
  jq -r '.assets[] | (.download // .name)' "$manifest" > "$work_dir/assets"
  while IFS= read -r name; do
    php_darwin_retry gh release download "$tag" --repo "$repo" --pattern "$name" --clobber --dir "$work_dir"
    hash=$(php_darwin_sha256 "$work_dir/$name")
    [ "$hash" = "$(jq -er --arg name "$name" '.assets[] | select((.download // .name)==$name) | .sha256' "$manifest")" ] || \
      php_darwin_die "release checksum mismatch: $name"
    printf '%s  %s\n' "$hash" "$name" > "$work_dir/$name.sha256"
  done < "$work_dir/assets"
fi
bash "$script_dir/mirror-release.sh" "$work_dir" "$mode"
if [ "${PUBLISH_INSTALLER:-false}" = true ]; then
  # Serialize this workflow with normal publishing, and detect any external
  # release change before replacing its installer. Archives are never rebuilt.
  mkdir "$work_dir/current"
  php_darwin_retry gh release download "$tag" --repo "$repo" --pattern "$tag-manifest.json" --clobber --dir "$work_dir/current"
  cmp -s "$manifest" "$work_dir/current/$tag-manifest.json" || php_darwin_die 'release changed while syncing'
  php_darwin_retry gh release upload "$tag" "$work_dir/install.sh" --clobber --repo "$repo"
  php_darwin_retry gh release download "$tag" --repo "$repo" --pattern install.sh --clobber --dir "$work_dir/current"
  cmp -s "$work_dir/install.sh" "$work_dir/current/install.sh" || php_darwin_die 'GitHub installer verification failed'
fi
