#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

builds_dir=${1:?}
version=${PHP_VERSION:?}
arch=$(php_darwin_normalize_arch "${ARCH:?}") || exit 1
source_commit=${HOMEBREW_PHP_COMMIT:?}
extension_source_commit=${HOMEBREW_EXTENSIONS_COMMIT:?}
channel=$(php_darwin_version_channel "$version") || exit 1
release_repository=$(php_darwin_package_config release_repository) || exit 1
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-restore.XXXXXX") || \
  php_darwin_die 'could not create the published-cache restore directory'
manifest="$work_dir/php-$version-manifest.json"
downloads="$work_dir/downloads.tsv"
download_pids=()
restore_files=()

cleanup() {
  local cleanup_status=$?
  local download_pid
  local restore_file

  trap - EXIT
  trap '' HUP INT TERM
  for download_pid in "${download_pids[@]}"; do
    php_darwin_reap_job "$download_pid" 0
  done
  if [ "$cleanup_status" -ne 0 ]; then
    for restore_file in "${restore_files[@]}"; do
      [ -n "$restore_file" ] || continue
      rm -f "$restore_file" "$restore_file.part"
    done
  fi
  rm -rf "$work_dir"
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || php_darwin_die 'invalid pinned homebrew-php source commit'
[[ "$extension_source_commit" =~ ^[0-9a-f]{40}$ ]] || \
  php_darwin_die 'invalid pinned homebrew-extensions source commit'
mkdir -p "$builds_dir" || php_darwin_die 'could not create the cache restore directory'
http_status=$(PHP_DARWIN_PREFER_MIRROR=true php_darwin_fetch_release_manifest "$release_repository" "$version" "$manifest") || \
  php_darwin_die "could not request the PHP $version release manifest"
[ "$http_status" = 200 ] || \
  php_darwin_die "could not fetch the PHP $version release manifest (HTTP $http_status)"
php_darwin_validate_release_manifest "$manifest" "$version" "$channel" >/dev/null || \
  php_darwin_die "could not validate the published PHP $version release manifest"
manifest_commits=$(jq -er '[.homebrew_php_commit,.homebrew_extensions_commit] | @tsv' "$manifest") || \
  php_darwin_die 'published release manifest does not contain both source commits'
IFS=$'\t' read -r manifest_source_commit manifest_extension_commit <<< "$manifest_commits" || \
  php_darwin_die 'could not read the published release source commits'
[ "$manifest_source_commit" = "$source_commit" ] && \
  [ "$manifest_extension_commit" = "$extension_source_commit" ] || \
  php_darwin_die 'published caches use different source commits from this partial build'

: > "$downloads" || php_darwin_die 'could not create the published-cache download plan'
while read -r build ts; do
  asset=$(php_darwin_asset "$version" "$build" "$ts" "$arch") || exit 1
  record=$(jq -er --arg asset "$asset" '
    [.assets[] | select(.name == $asset)] |
    select(length == 1) | .[0] | [.name,(.download // .name),.sha256,(.bytes | tostring)] | @tsv
  ' "$manifest") || php_darwin_die "published release does not contain $asset"
  printf '%s\n' "$record" >> "$downloads" || php_darwin_die 'could not record a published cache download'
done < <(php_darwin_configured_variants)

while IFS=$'\t' read -r asset download_asset expected_hash expected_bytes; do
  [[ "$asset" =~ ^php_[0-9]+\.[0-9]+-(nts|zts)-(debug|release)\+darwin_(arm64|x86_64)\.tar\.zst$ ]] || \
    php_darwin_die "invalid published cache name: $asset"
  [[ "$download_asset" =~ ^php_[0-9]+\.[0-9]+-(nts|zts)-(debug|release)\+darwin_(arm64|x86_64)\.[0-9a-f]{64}\.tar\.zst$ ]] || \
    php_darwin_die "invalid published cache download name: $download_asset"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] && [[ "$expected_bytes" =~ ^[0-9]+$ ]] || \
    php_darwin_die "invalid published cache integrity record: $asset"
  archive="$builds_dir/$asset"
  [ ! -e "$archive" ] && [ ! -L "$archive" ] || php_darwin_die "cache already exists: $archive"
  metadata="$builds_dir/${asset%.tar.zst}.json"
  restore_files+=("$archive" "$archive.sha256" "$metadata")
  (
    mirror=$(php_darwin_release_mirror "$release_repository" "$version") || exit 1
    urls=()
    [ -z "$mirror" ] || urls+=("$mirror/$download_asset")
    urls+=("https://github.com/$release_repository/releases/download/php-$version/$download_asset")
    for url in "${urls[@]}"; do
      # Cache construction prefers Cloudflare. Each origin gets one bounded
      # attempt; only a complete, authenticated archive becomes a build input.
      status=$(php_darwin_request_release "$url" "$archive.part") || continue
      [ "$status" = 200 ] || continue
      [ "$(wc -c < "$archive.part" | tr -d '[:space:]')" = "$expected_bytes" ] || continue
      [ "$(php_darwin_sha256 "$archive.part")" = "$expected_hash" ] || continue
      mv "$archive.part" "$archive" || exit 1
      exit 0
    done
    exit 1
  ) &
  download_pids+=("$!")
done < "$downloads"

download_failed=false
for download_pid in "${download_pids[@]}"; do
  wait "$download_pid" || download_failed=true
done
download_pids=()
[ "$download_failed" = false ] || php_darwin_die "could not download published $arch caches"

while IFS=$'\t' read -r asset _ expected_hash expected_bytes; do
  archive="$builds_dir/$asset"
  actual_hash=$(php_darwin_sha256 "$archive") || php_darwin_die "could not hash restored cache $asset"
  [ "$actual_hash" = "$expected_hash" ] || php_darwin_die "checksum mismatch for restored cache $asset"
  actual_bytes=$(wc -c < "$archive" | tr -d '[:space:]')
  [ "$actual_bytes" = "$expected_bytes" ] || php_darwin_die "size mismatch for restored cache $asset"
  metadata="$builds_dir/${asset%.tar.zst}.json"
  internal_metadata=$(php_darwin_metadata_path "$asset") || exit 1
  bash "$script_dir/../installer/read-metadata.sh" "$archive" "$internal_metadata" "$metadata" || \
    php_darwin_die "could not read metadata from restored cache $asset"
  printf '%s  %s\n' "$actual_hash" "$asset" > "$archive.sha256" || \
    php_darwin_die "could not write the restored cache checksum for $asset"
done < "$downloads"

printf 'Restored %s published %s cache variants\n' \
  "$(awk 'END { print NR+0 }' "$downloads")" "$arch"
