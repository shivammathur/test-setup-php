#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"
# shellcheck source=scripts/lib/retry.sh
. "$script_dir/../lib/retry.sh"

builds_dir=${1:?}
expected_version=${PHP_VERSION:-}
source_commit=${HOMEBREW_PHP_COMMIT:-}
extension_source_commit=${HOMEBREW_EXTENSIONS_COMMIT:-}
release_repository=$(php_darwin_package_config release_repository) || exit 1
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-publish.XXXXXX") || \
  php_darwin_die 'could not create the release staging directory'
release_exists=false
release_created=false
release_committed=false
mutable_mutation_started=false
previous_assets="$work_dir/previous-assets"
publish_cleanup() {
  local cleanup_status=$?
  local previous_asset
  local previous_asset_files=()

  trap - EXIT
  trap '' HUP INT TERM
  if [ "$cleanup_status" -ne 0 ] && [ "$release_committed" = false ] && \
    [ "$mutable_mutation_started" = true ] && \
    [ "$release_exists" = true ] && [ -d "$previous_assets" ]; then
    while IFS= read -r -d '' previous_asset; do
      previous_asset_files+=("$previous_asset")
    done < <(find "$previous_assets" -type f -print0)
    if [ "${#previous_asset_files[@]}" -gt 0 ]; then
      printf 'Restoring the previous %s release assets after a failed publish\n' "$tag" >&2
      php_darwin_retry gh release upload "$tag" "${previous_asset_files[@]}" --clobber \
        --repo "$release_repository" >/dev/null 2>&1 || \
        printf 'Could not fully restore the previous %s release assets\n' "$tag" >&2
    fi
  elif [ "$cleanup_status" -ne 0 ] && [ "$release_committed" = false ] && \
    [ "$release_created" = true ]; then
    php_darwin_retry gh release delete "$tag" --cleanup-tag --yes --repo "$release_repository" >/dev/null 2>&1 || \
      printf 'Could not remove the incomplete %s release\n' "$tag" >&2
  fi
  rm -rf "$work_dir"
  exit "$cleanup_status"
}
trap publish_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
metadata_unsorted="$work_dir/metadata-unsorted.txt"
metadata_list="$work_dir/metadata.txt"
matrix_keys="$work_dir/matrix-keys.txt"
formulae="$work_dir/formulae.tsv"
source_hashes="$work_dir/source-hashes.txt"
extensions_source_hashes="$work_dir/extensions-source-hashes.txt"
semvers="$work_dir/semvers.txt"
php_src_commits="$work_dir/php-src-commits.txt"
assets_jsonl="$work_dir/assets.jsonl"
retained_assets="$work_dir/retained-assets.txt"
release_assets_json="$work_dir/release-assets.json"
release_asset_names="$work_dir/release-asset-names.txt"
stale_assets="$work_dir/stale-assets.txt"
retired_assets="$work_dir/retired-assets.txt"
staging="$work_dir/release"

[ -z "$expected_version" ] || php_darwin_validate_version "$expected_version"
[[ "$release_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  php_darwin_die "invalid release repository: $release_repository"
mkdir -p "$staging" || php_darwin_die 'could not create the release staging directory'
find "$builds_dir" -type f -name 'php_*.json' -print > "$metadata_unsorted" || \
  php_darwin_die 'could not locate cache metadata'
LC_ALL=C sort "$metadata_unsorted" > "$metadata_list" || php_darwin_die 'could not sort cache metadata'
[ -s "$metadata_list" ] || php_darwin_die 'no cache metadata found'
if [ -z "$source_commit" ]; then
  IFS= read -r first_metadata < "$metadata_list"
  source_commit=$(jq -er '.homebrew_php_commit' "$first_metadata") || \
    php_darwin_die 'could not derive the pinned homebrew-php source commit'
fi
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || php_darwin_die 'invalid pinned homebrew-php source commit'
if [ -z "$extension_source_commit" ]; then
  [ -n "${first_metadata:-}" ] || IFS= read -r first_metadata < "$metadata_list"
  extension_source_commit=$(jq -er '.homebrew_extensions_commit' "$first_metadata") || \
    php_darwin_die 'could not derive the pinned homebrew-extensions source commit'
fi
[[ "$extension_source_commit" =~ ^[0-9a-f]{40}$ ]] || \
  php_darwin_die 'invalid pinned homebrew-extensions source commit'
: > "$matrix_keys"
: > "$formulae"
: > "$source_hashes"
: > "$extensions_source_hashes"
: > "$semvers"
: > "$php_src_commits"
: > "$assets_jsonl"

version=
data_upload_files=()
while IFS= read -r metadata; do
  metadata_version=$(jq -er '.php_version' "$metadata") || php_darwin_die "PHP version is missing in $metadata"
  [ -z "$expected_version" ] || [ "$metadata_version" = "$expected_version" ] || \
    php_darwin_die "metadata PHP version is $metadata_version; expected $expected_version"
  [ -n "$version" ] || version=$metadata_version
  [ "$metadata_version" = "$version" ] || php_darwin_die 'publish input contains multiple PHP minor versions'
  channel=$(php_darwin_version_channel "$version") || exit 1
  metadata_php_src_commit=$(jq -er --arg channel "$channel" '
    select(.schema == 1 and has("php_src_commit")) |
    if $channel == "nightly" then
      .php_src_commit | select(type == "string" and test("^[0-9a-f]{40}$"))
    elif $channel == "stable" then
      if .php_src_commit == null or .php_src_commit == "" then "-" else error("invalid") end
    else
      error("invalid channel")
    end
  ' "$metadata") || \
    php_darwin_die "PHP source commit is missing in $metadata"
  case "$channel" in
    nightly) [[ "$metadata_php_src_commit" =~ ^[0-9a-f]{40}$ ]] || \
      php_darwin_die "nightly PHP source commit is invalid in $metadata" ;;
    stable) [ "$metadata_php_src_commit" = - ] || \
      php_darwin_die "stable PHP source commit must be empty in $metadata" ;;
  esac
  metadata_build=$(jq -er '.build' "$metadata") || php_darwin_die "build type is missing in $metadata"
  metadata_ts=$(jq -er '.thread_safety' "$metadata") || php_darwin_die "thread safety is missing in $metadata"
  metadata_arch=$(jq -er '.architecture' "$metadata") || php_darwin_die "architecture is missing in $metadata"
  php_darwin_validate_build "$metadata_build"
  php_darwin_validate_ts "$metadata_ts"
  metadata_arch=$(php_darwin_normalize_arch "$metadata_arch") || exit 1
  expected_archive=$(php_darwin_asset "$version" "$metadata_build" "$metadata_ts" "$metadata_arch") || exit 1
  expected_prefix=$(php_darwin_platform_value "$metadata_arch" brew_prefix) || \
    php_darwin_die "brew prefix is not configured for $metadata_arch"
  expected_minimum=$(php_darwin_platform_value "$metadata_arch" minimum_macos) || \
    php_darwin_die "minimum macOS is not configured for $metadata_arch"

  php_darwin_validate_cache_metadata "$metadata" "$version" "$metadata_build" "$metadata_ts" \
    "$metadata_arch" "$expected_prefix" "$expected_minimum" "$source_commit" \
    "$metadata_php_src_commit" '' '' '' '' "$extension_source_commit" \
    "$(jq -er '.extensions_source_hash | select(type == "string" and test("^[0-9a-f]{64}$"))' "$metadata")" \
    >/dev/null || \
    php_darwin_die "metadata validation failed: $metadata"
  if ! cmp -s <(bash "$script_dir/../build/cached-extensions.sh" "$version" records | LC_ALL=C sort -u) \
    <(jq -r '.extensions[] | [.name,.type] | @tsv' "$metadata" | LC_ALL=C sort -u); then
    php_darwin_die "cached extension metadata is incomplete: $metadata"
  fi
  [ "$(basename "$metadata")" = "${expected_archive%.tar.zst}.json" ] || \
    php_darwin_die "metadata filename does not match its archive: $metadata"

  archive_matches="$work_dir/archive-matches.txt"
  find "$builds_dir" -type f -name "$expected_archive" -print > "$archive_matches" || \
    php_darwin_die "could not locate $expected_archive"
  [ "$(awk 'END { print NR+0 }' "$archive_matches")" -eq 1 ] || \
    php_darwin_die "expected exactly one archive named $expected_archive"
  IFS= read -r archive < "$archive_matches"
  checksum="$archive.sha256"
  [ -f "$checksum" ] || php_darwin_die "checksum not found: $checksum"
  expected_hash=$(php_darwin_checksum_from_file "$checksum" "$expected_archive") || \
    php_darwin_die "checksum record not found for $expected_archive"
  actual_hash=$(php_darwin_sha256 "$archive") || php_darwin_die "could not hash $expected_archive"
  [ "$actual_hash" = "$expected_hash" ] || php_darwin_die "checksum mismatch before publish: $expected_archive"
  archive_bytes=$(wc -c < "$archive" | tr -d '[:space:]')
  [[ "$archive_bytes" =~ ^[0-9]+$ ]] || php_darwin_die "invalid archive size for $expected_archive"
  download_asset=$(php_darwin_download_asset "$expected_archive" "$actual_hash") || \
    php_darwin_die "could not create the immutable release name for $expected_archive"
  cp "$archive" "$staging/$download_asset" || php_darwin_die "could not stage $expected_archive"
  printf '%s  %s\n' "$actual_hash" "$download_asset" > "$staging/$download_asset.sha256" || \
    php_darwin_die "could not stage the checksum for $expected_archive"
  data_upload_files+=("$staging/$download_asset" "$staging/$download_asset.sha256")

  printf '%s/%s/%s\n' "$metadata_build" "$metadata_ts" "$metadata_arch" >> "$matrix_keys"
  jq -r '[.formula,.formula_sha256] | @tsv' "$metadata" >> "$formulae" || \
    php_darwin_die "could not read formula metadata from $metadata"
  jq -er '.source_hash' "$metadata" >> "$source_hashes" || php_darwin_die "could not read source hash from $metadata"
  jq -er '.extensions_source_hash' "$metadata" >> "$extensions_source_hashes" || \
    php_darwin_die "could not read extension source hash from $metadata"
  jq -er '.php_semver' "$metadata" >> "$semvers" || php_darwin_die "could not read PHP version from $metadata"
  [ "$metadata_php_src_commit" != - ] || metadata_php_src_commit=
  printf '%s\n' "$metadata_php_src_commit" >> "$php_src_commits" || \
    php_darwin_die "could not read the PHP source commit from $metadata"
  jq -cn --arg architecture "$metadata_arch" --arg build "$metadata_build" --arg download "$download_asset" \
    --slurpfile metadata "$metadata" \
    --arg name "$expected_archive" \
    --arg sha256 "$actual_hash" --arg thread_safety "$metadata_ts" --argjson bytes "$archive_bytes" \
    --argjson minimum_macos "$expected_minimum" \
    '{architecture:$architecture,build:$build,bytes:$bytes,download:$download,minimum_macos:$minimum_macos,name:$name,
      sha256:$sha256,thread_safety:$thread_safety} +
      (if $metadata[0].build_inputs then {build_inputs:$metadata[0].build_inputs} else {} end)' >> "$assets_jsonl" || \
    php_darwin_die "could not create the release record for $expected_archive"
done < "$metadata_list"

variant_count=$(php_darwin_configured_variants | awk 'END { print NR+0 }') || \
  php_darwin_die 'could not count configured build variants'
expected_count=$(php_darwin_expected_asset_count) || exit 1
metadata_count=$(awk 'END { print NR+0 }' "$metadata_list")
[ "$metadata_count" -eq "$expected_count" ] || \
  php_darwin_die "incomplete publish matrix; expected $expected_count metadata files, found $metadata_count"
LC_ALL=C sort -u "$matrix_keys" -o "$matrix_keys" || php_darwin_die 'could not sort publish matrix keys'
[ "$(awk 'END { print NR+0 }' "$matrix_keys")" -eq "$expected_count" ] || \
  php_darwin_die 'publish matrix contains duplicate or missing build keys'
LC_ALL=C sort -u "$formulae" -o "$formulae" || php_darwin_die 'could not sort formula hashes'
[ "$(awk 'END { print NR+0 }' "$formulae")" -eq "$variant_count" ] || \
  php_darwin_die "expected $variant_count unique formula source hashes"
computed_source_hash=$(php_darwin_sha256 "$formulae") || php_darwin_die 'could not hash formula metadata'
LC_ALL=C sort -u "$source_hashes" -o "$source_hashes" || php_darwin_die 'could not sort source hashes'
[ "$(awk 'END { print NR+0 }' "$source_hashes")" -eq 1 ] || \
  php_darwin_die 'build variants disagree on the formula source hash'
IFS= read -r source_hash < "$source_hashes"
[ "$source_hash" = "$computed_source_hash" ] || php_darwin_die 'formula source hash does not match the metadata'
LC_ALL=C sort -u "$extensions_source_hashes" -o "$extensions_source_hashes" || \
  php_darwin_die 'could not sort cached extension source hashes'
[ "$(awk 'END { print NR+0 }' "$extensions_source_hashes")" -eq 1 ] || \
  php_darwin_die 'build variants disagree on the cached extension source hash'
IFS= read -r extensions_source_hash < "$extensions_source_hashes" || \
  php_darwin_die 'could not read the cached extension source hash'
LC_ALL=C sort -u "$semvers" -o "$semvers" || php_darwin_die 'could not sort PHP semantic versions'
[ "$(awk 'END { print NR+0 }' "$semvers")" -eq 1 ] || \
  php_darwin_die 'build variants disagree on the PHP semantic version'
IFS= read -r semver < "$semvers"
LC_ALL=C sort -u "$php_src_commits" -o "$php_src_commits" || \
  php_darwin_die 'could not sort PHP source commits'
[ "$(awk 'END { print NR+0 }' "$php_src_commits")" -eq 1 ] || \
  php_darwin_die 'build variants disagree on the PHP source commit'
IFS= read -r php_src_commit < "$php_src_commits" || php_src_commit=
case "$channel" in
  nightly) [[ "$php_src_commit" =~ ^[0-9a-f]{40}$ ]] || php_darwin_die 'nightly PHP source commit is invalid' ;;
  stable) [ -z "$php_src_commit" ] || php_darwin_die 'stable PHP source commit must be empty' ;;
esac

tag="php-$version"
manifest="$staging/$tag-manifest.json"
installer="$staging/install.sh"
jq --slurpfile assets "$assets_jsonl" --arg commit "$source_commit" \
  --arg extensions_commit "$extension_source_commit" --arg extensions_source_hash "$extensions_source_hash" \
  --arg php_semver "$semver" \
  --arg php_src_commit "$php_src_commit" --arg php_version "$version" --arg source_hash "$source_hash" '
  .assets=($assets | sort_by(.build,.thread_safety,.architecture)) |
  .extensions_source_hash=$extensions_source_hash |
  .homebrew_extensions_commit=$extensions_commit | .homebrew_php_commit=$commit |
  .php_semver=$php_semver | .php_src_commit=$php_src_commit |
  .php_version=$php_version |
  .source_hash=$source_hash
' "$script_dir/../../templates/release-manifest.json" > "$manifest" || \
  php_darwin_die 'could not create the release manifest'
php_darwin_validate_release_manifest "$manifest" "$version" "$channel" || \
  php_darwin_die 'release manifest validation failed'
bash "$script_dir/../installer/validate-install.sh" >/dev/null || \
  php_darwin_die 'standalone installer validation failed before publish'
PHP_DARWIN_RELEASE_MANIFEST="$manifest" bash "$script_dir/../installer/generate-install.sh" "$installer" >/dev/null || \
  php_darwin_die 'could not generate the release-specific standalone installer'

if php_darwin_retry gh release view "$tag" --repo "$release_repository" --json assets > "$release_assets_json" 2>/dev/null; then
  release_exists=true
  mkdir -p "$previous_assets" || php_darwin_die 'could not create the release backup directory'
  jq -e '(.assets | type == "array") and
    ([.assets[].name] | unique | length) == (.assets | length) and all(.assets[];
    (.name | type == "string") and (.state | type == "string") and
    ((.digest // "") | type == "string") and ((.apiUrl // "") | type == "string"))' \
    "$release_assets_json" >/dev/null || php_darwin_die "could not inspect existing release assets for $tag"
  jq -r '.assets[].name' "$release_assets_json" > "$release_asset_names" || \
    php_darwin_die "could not read existing release asset names for $tag"
  for mutable_asset in install.sh "$tag-manifest.json"; do
    grep -Fxq "$mutable_asset" "$release_asset_names" || continue
    mutable_state=$(jq -er --arg name "$mutable_asset" \
      '.assets[] | select(.name == $name) | .state | select(type == "string")' \
      "$release_assets_json") || php_darwin_die "could not inspect $mutable_asset"
    mutable_digest=$(jq -er --arg name "$mutable_asset" \
      '.assets[] | select(.name == $name) | (.digest // "") | select(type == "string")' \
      "$release_assets_json") || php_darwin_die "could not inspect $mutable_asset digest"
    if [ "$mutable_state" = uploaded ] && \
      { [ -z "$mutable_digest" ] || [[ "$mutable_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; }; then
      php_darwin_retry gh release download "$tag" --pattern "$mutable_asset" --clobber --dir "$previous_assets" \
        --repo "$release_repository" || \
        php_darwin_die "could not back up existing release asset $mutable_asset"
      if [ -n "$mutable_digest" ]; then
        [ "sha256:$(php_darwin_sha256 "$previous_assets/$mutable_asset")" = "$mutable_digest" ] || \
          php_darwin_die "existing release asset digest changed while backing up $mutable_asset"
      fi
    else
      printf 'Replacing incomplete release asset %s without using it as a rollback source\n' \
        "$mutable_asset" >&2
    fi
  done
else
  php_darwin_retry gh release create "$tag" --repo "$release_repository" --title "PHP $version" \
    --notes "Architecture-specific Homebrew PHP $version caches for macOS runners." --latest=false || \
    php_darwin_die "could not create release $tag"
  release_created=true
  printf '{"assets":[]}\n' > "$release_assets_json" || \
    php_darwin_die 'could not initialize the release asset inventory'
  : > "$release_asset_names" || php_darwin_die 'could not initialize the release asset names'
fi

# Prepare retention and cleanup decisions before publishing the commit point.
jq -r '.assets[] | .download, (.download + ".sha256")' "$manifest" > "$retained_assets" || \
  php_darwin_die 'could not record the current immutable release assets'
previous_manifest_valid=false
if [ -f "$previous_assets/$tag-manifest.json" ] && \
  php_darwin_validate_release_manifest "$previous_assets/$tag-manifest.json" "$version" "$channel"; then
  previous_manifest_valid=true
  jq -r '.assets[] | (.download // .name) as $download | $download, ($download + ".sha256")' \
    "$previous_assets/$tag-manifest.json" >> "$retained_assets" || \
    php_darwin_die 'could not record the previous immutable release assets'
fi
LC_ALL=C sort -u "$retained_assets" -o "$retained_assets" || \
  php_darwin_die 'could not sort the retained immutable release assets'
: > "$stale_assets" || php_darwin_die 'could not initialize stale release assets'
: > "$retired_assets" || php_darwin_die 'could not initialize retired release assets'
while IFS= read -r previous_name; do
  if [[ "$previous_name" =~ ^php_[0-9]+\.[0-9]+-(nts|zts)-(debug|release)\+darwin_(arm64|x86_64)\.[0-9a-f]{64}\.tar\.zst(\.sha256)?\.invalid\.[0-9]+$ ]]; then
    printf '%s\n' "$previous_name" >> "$retired_assets" || \
      php_darwin_die 'could not record a quarantined release asset'
  elif [[ "$previous_name" =~ ^php_[0-9]+\.[0-9]+-(nts|zts)-(debug|release)\+darwin_(arm64|x86_64)\.[0-9a-f]{64}\.tar\.zst(\.sha256)?$ ]]; then
    if [ "$previous_manifest_valid" = true ] && ! grep -Fxq "$previous_name" "$retained_assets"; then
      printf '%s\n' "$previous_name" >> "$stale_assets" || \
        php_darwin_die 'could not record a stale immutable release asset'
    fi
  elif [[ "$previous_name" =~ ^php_[0-9]+\.[0-9]+-(nts|zts)-(debug|release)\+darwin_(arm64|x86_64)(\.[0-9a-f]{64})?\.tar\.zst(\.sha256)?$ ]]; then
    printf '%s\n' "$previous_name" >> "$retired_assets" || \
      php_darwin_die 'could not record a retired mutable release asset'
  fi
done < "$release_asset_names"

upload_files=()
for upload_file in "${data_upload_files[@]}"; do
  upload_name=${upload_file##*/}
  upload_digest="sha256:$(php_darwin_sha256 "$upload_file")" || \
    php_darwin_die "could not hash staged release asset $upload_name"
  matching_assets=$(jq -r --arg name "$upload_name" '[.assets[] | select(.name == $name)] | length' \
    "$release_assets_json") || php_darwin_die "could not inspect release asset $upload_name"
  case "$matching_assets" in
    0) upload_files+=("$upload_file") ;;
    1)
      existing_state=$(jq -er --arg name "$upload_name" \
        '.assets[] | select(.name == $name) | .state | select(type == "string")' \
        "$release_assets_json") || php_darwin_die "could not inspect release asset $upload_name state"
      existing_digest=$(jq -er --arg name "$upload_name" \
        '.assets[] | select(.name == $name) | (.digest // "") | select(type == "string")' \
        "$release_assets_json") || php_darwin_die "could not inspect release asset $upload_name digest"
      if [ "$existing_state" != uploaded ] || \
        { [ -n "$existing_digest" ] && [ "$existing_digest" != "$upload_digest" ]; }; then
        existing_api_url=$(jq -er --arg name "$upload_name" \
          '.assets[] | select(.name == $name) | .apiUrl | select(type == "string" and length > 0)' \
          "$release_assets_json") || php_darwin_die "release asset $upload_name has no API URL"
        invalid_name="$upload_name.invalid.${existing_api_url##*/}"
        php_darwin_retry gh api --method PATCH "$existing_api_url" -f "name=$invalid_name" >/dev/null || \
          php_darwin_die "could not quarantine corrupt release asset $upload_name"
        if ! php_darwin_upload_immutable "$tag" "$release_repository" "$upload_file"; then
          php_darwin_retry gh api --method PATCH "$existing_api_url" -f "name=$upload_name" >/dev/null 2>&1 || \
            printf 'Could not restore corrupt release asset name %s\n' "$upload_name" >&2
          php_darwin_die "could not repair release asset $upload_name"
        fi
        php_darwin_retry gh release delete-asset "$tag" "$invalid_name" --yes --repo "$release_repository" || \
          php_darwin_die "could not remove quarantined release asset $invalid_name"
      fi
      ;;
    *) php_darwin_die "release contains duplicate assets named $upload_name" ;;
  esac
done
if [ "${#upload_files[@]}" -gt 0 ]; then
  php_darwin_upload_immutable "$tag" "$release_repository" "${upload_files[@]}" || \
    php_darwin_die "could not upload release archives to $tag"
fi
# Verify the independent fallback before advertising the new GitHub release.
if [ "${PHP_DARWIN_MIRROR_REQUIRED:-false}" = true ] || [ -n "${CF_R2_AWS_ACCESS_KEY_ID:-}" ]; then
  PHP_VERSION="$version" bash "$script_dir/mirror-release.sh" "$staging" || \
    php_darwin_die "could not mirror the verified release $tag"
fi
mutable_mutation_started=true
php_darwin_retry gh release upload "$tag" "$installer" --clobber --repo "$release_repository" || \
  php_darwin_die "could not upload the release installer to $tag"
# The manifest is the release commit point. Upload it only after every archive,
# checksum, and the matching embedded-manifest installer is available.
php_darwin_retry gh release upload "$tag" "$manifest" --clobber --repo "$release_repository" || \
  php_darwin_die "could not commit release assets for $tag"
release_committed=true

# Old content-addressed cleanup is best-effort after the manifest commit point.
# Retired mutable names are mandatory removals so old clients fail closed
# instead of silently installing frozen builds.
while IFS= read -r stale_asset; do
  [ -n "$stale_asset" ] || continue
  if ! php_darwin_retry gh release delete-asset "$tag" "$stale_asset" --yes --repo "$release_repository" \
    >/dev/null 2>&1; then
    printf 'Could not remove stale release asset %s from %s\n' "$stale_asset" "$tag" >&2
  fi
done < "$stale_assets"
retired_cleanup_failed=false
while IFS= read -r retired_asset; do
  [ -n "$retired_asset" ] || continue
  if ! php_darwin_retry gh release delete-asset "$tag" "$retired_asset" --yes --repo "$release_repository" \
    >/dev/null 2>&1; then
    printf 'Could not remove retired release asset %s from %s\n' "$retired_asset" "$tag" >&2
    retired_cleanup_failed=true
  fi
done < "$retired_assets"
[ "$retired_cleanup_failed" = false ] || \
  php_darwin_die "retired release assets remain in $tag"
printf 'Published PHP %s release assets with source hash %s\n' "$version" "$source_hash"
