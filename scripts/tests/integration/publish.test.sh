#!/usr/bin/env bash

export HOMEBREW_EXTENSIONS_COMMIT='' HOMEBREW_PHP_COMMIT=''

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-publish-test.XXXXXX") || \
  php_darwin_die 'could not create publish test fixtures'
trap 'rm -rf "$work_dir"' EXIT
builds_dir="$work_dir/builds"
fake_bin="$work_dir/bin"
formulae="$work_dir/formulae.tsv"
gh_log="$work_dir/gh.log"
gh_manifest="$work_dir/release-manifest.json"
gh_installer="$work_dir/install.sh"
version=7.0
semver=7.0.33
source_commit=0123456789abcdef0123456789abcdef01234567
extension_source_commit=89abcdef0123456789abcdef0123456789abcdef
extensions_source_hash=$(printf '%064d' 9)
mkdir -p "$builds_dir" "$fake_bin" || php_darwin_die 'could not create publish fixtures'
cp "$script_dir/../fixtures/gh.sh" "$fake_bin/gh" || php_darwin_die 'could not copy the gh fixture'
printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/sleep"
chmod 0755 "$fake_bin/sleep"
chmod 0755 "$fake_bin/gh" || php_darwin_die 'could not make the gh fixture executable'

php_darwin_test_release_assets() {
  local asset_file
  local asset_hash
  local asset_id=0
  local asset_records="$2.records"
  local assets_dir=$1
  local output=$2

  : > "$asset_records" || return 1
  for asset_file in "$assets_dir"/*; do
    [ -f "$asset_file" ] || continue
    asset_id=$((asset_id + 1))
    asset_hash=$(php_darwin_sha256 "$asset_file") || return 1
    jq -cn --arg api_url "https://api.github.test/assets/$asset_id" \
      --arg digest "sha256:$asset_hash" --arg name "${asset_file##*/}" \
      --argjson size "$(wc -c < "$asset_file" | tr -d '[:space:]')" \
      '{apiUrl:$api_url,name:$name,digest:$digest,size:$size,state:"uploaded"}' \
      >> "$asset_records" || return 1
  done
  jq -s '{assets:.}' "$asset_records" > "$output"
}

: > "$formulae"
variant_index=0
while read -r build ts; do
  variant_index=$((variant_index + 1))
  formula=$(php_darwin_formula "$version" "$build" "$ts") || exit 1
  formula_hash=$(printf '%064d' "$variant_index")
  printf '%s\t%s\n' "$formula" "$formula_hash" >> "$formulae" || \
    php_darwin_die 'could not create formula fixtures'
done < <(php_darwin_configured_variants)
LC_ALL=C sort -u "$formulae" -o "$formulae" || php_darwin_die 'could not sort formula fixtures'
source_hash=$(php_darwin_sha256 "$formulae") || php_darwin_die 'could not hash formula fixtures'

while read -r build ts; do
  formula=$(php_darwin_formula "$version" "$build" "$ts") || exit 1
  requested=$(php_darwin_requested_formula "$version" "$build" "$ts") || exit 1
  formula_hash=$(awk -F '\t' -v formula="$formula" '$1 == formula { print $2; found=1; exit } END { exit !found }' \
    "$formulae") || php_darwin_die "could not read fixture hash for $formula"
  while IFS= read -r arch; do
    asset=$(php_darwin_asset "$version" "$build" "$ts" "$arch") || exit 1
    artifact_dir="$builds_dir/$build-$ts-$arch"
    archive="$artifact_dir/$asset"
    metadata="$artifact_dir/${asset%.tar.zst}.json"
    prefix=$(php_darwin_platform_value "$arch" brew_prefix) || exit 1
    minimum=$(php_darwin_platform_value "$arch" minimum_macos) || exit 1
    platform=$(php_darwin_platform_value "$arch" platform_key) || exit 1
    mkdir -p "$artifact_dir" || php_darwin_die 'could not create an artifact fixture directory'
    printf 'archive fixture for %s/%s/%s\n' "$build" "$ts" "$arch" > "$archive"
    archive_hash=$(php_darwin_sha256 "$archive") || php_darwin_die 'could not hash an archive fixture'
    printf '%s  %s\n' "$archive_hash" "$asset" > "$archive.sha256"
    jq --arg archive "$asset" --arg architecture "$arch" --arg brew_prefix "$prefix" \
      --arg build "$build" --arg formula "$formula" --arg formula_sha256 "$formula_hash" \
      --arg extensions_source_hash "$extensions_source_hash" \
      --arg homebrew_extensions_commit "$extension_source_commit" \
      --arg homebrew_php_commit "$source_commit" --argjson minimum_macos "$minimum" \
      --arg pear_path "$(php_darwin_pear_path "$version" "$formula")" --arg pecl_extension 20250925 \
      --arg php_semver "$semver" --arg php_src_commit '' --arg php_version "$version" --arg platform_key "$platform" \
      --arg requested_formula "$requested" --arg source_hash "$source_hash" \
      --arg config_id "$(php_darwin_config_id "$version" "$build" "$ts")" \
      --arg tap_snapshot "$(php_darwin_package_config tap_snapshot)" --arg thread_safety "$ts" '
      .archive=$archive | .architecture=$architecture | .brew_prefix=$brew_prefix | .build=$build |
      .created_at="2026-01-01T00:00:00Z" | .extensions_source_hash=$extensions_source_hash |
      .formula=$formula | .formula_sha256=$formula_sha256 |
      .extensions=[{name:"xdebug",type:"zend_extension",path:("lib/php/" + $pecl_extension + "/xdebug.so")}] |
      .homebrew_extensions_commit=$homebrew_extensions_commit |
      .homebrew_php_commit=$homebrew_php_commit | .macos_version="15.0" | .minimum_macos=$minimum_macos |
      .links=[{path:"bin/php",target:("../Cellar/" + $formula + "/" + $php_semver + "/bin/php")}] |
      .packages=[{name:$formula,opt_target:("../Cellar/" + $formula + "/" + $php_semver),keg_only:false}] |
      .pear_path=$pear_path | .pecl_extension=$pecl_extension | .php_semver=$php_semver |
      .php_src_commit=$php_src_commit | .php_version=$php_version | .platform_key=$platform_key |
      .requested_formula=$requested_formula |
      .runner_image="fixture" | .source_hash=$source_hash |
      .build_inputs={schema:1,builder_sha256:$source_hash,source_records:[{repository:"Homebrew/homebrew-core",path:"Formula/o/openssl@3.rb",sha256:$source_hash}]} |
      .state_paths=[("etc/php/" + $config_id + "/pear.conf")] | .tap_formulae=[$formula] |
      .tap_snapshot=$tap_snapshot |
      .thread_safety=$thread_safety
    ' "$script_dir/../../../templates/cache-metadata.json" > "$metadata" || \
      php_darwin_die 'could not write metadata fixture'
  done < <(php_darwin_platform_arches)
done < <(php_darwin_configured_variants)

# One schema-1 stable cache may still use the legacy explicit null. Publishing
# must normalize it without accepting a missing field.
jq '.php_src_commit=null' "$metadata" > "$metadata.legacy" || \
  php_darwin_die 'could not create a legacy publisher input fixture'
mv "$metadata.legacy" "$metadata" || php_darwin_die 'could not install the legacy publisher input fixture'

export GH_LOG=$gh_log
export GH_MANIFEST=$gh_manifest
export GH_INSTALLER=$gh_installer
: > "$gh_log"
HOMEBREW_EXTENSIONS_COMMIT="$extension_source_commit" PHP_VERSION="$version" PATH="$fake_bin:$PATH" \
  bash "$script_dir/../../release/publish.sh" "$builds_dir" >/dev/null || \
  php_darwin_die 'publish fixture validation failed'
jq -e 'all(.assets[]; .build_inputs.schema == 1 and (.build_inputs.source_records | length) == 1)' "$gh_manifest" >/dev/null || \
  php_darwin_die 'publication lost dependency freshness inputs'
[ "$(awk 'END { print NR+0 }' "$gh_log")" -eq 7 ] || \
  php_darwin_die 'publisher did not view, create, and upload the release in three phases'
grep -Eq '^release view php-7\.0 ' "$gh_log" || php_darwin_die 'publisher did not inspect the minor release'
grep -Eq '^release create php-7\.0 ' "$gh_log" || php_darwin_die 'publisher did not create the minor release'
grep -Eq '^release upload php-7\.0 .*\.[0-9a-f]{64}\.tar\.zst(\.sha256)?( .*\.[0-9a-f]{64}\.tar\.zst(\.sha256)?)* --repo shivammathur/php-darwin$' \
  "$gh_log" || php_darwin_die 'publisher did not upload immutable release assets'
grep -Eq '^release upload php-7\.0 .*release/install\.sh .*--clobber' "$gh_log" || \
  php_darwin_die 'publisher did not upload the standalone installer'
grep -Eq '^release upload php-7\.0 .*\.[0-9a-f]{64}\.tar\.zst\.sha256 .*--repo shivammathur/php-darwin$' \
  "$gh_log" || \
  php_darwin_die 'publisher did not upload archive checksum sidecars'
tail -n 1 "$gh_log" | grep -Eq '^release upload php-7\.0 .*/php-7\.0-manifest\.json --clobber --repo shivammathur/php-darwin$' || \
  php_darwin_die 'publisher did not upload the release manifest as the commit point'
jq -e --arg extensions_source_hash "$extensions_source_hash" --arg source_hash "$source_hash" \
  --argjson count "$(php_darwin_expected_asset_count)" '
  .schema == 1 and .php_version == "7.0" and .php_semver == "7.0.33" and
  .php_src_commit == "" and
  .homebrew_extensions_commit == "89abcdef0123456789abcdef0123456789abcdef" and
  .extensions_source_hash == $extensions_source_hash and
  .homebrew_php_commit == "0123456789abcdef0123456789abcdef01234567" and
  .source_hash == $source_hash and (.assets | length == $count) and
  ([.assets[].name] | unique | length == $count) and
  all(.assets[]; . as $item |
    .download == ($item.name | sub("\\.tar\\.zst$"; "." + $item.sha256 + ".tar.zst"))) and
  ([.assets[].architecture] | unique | sort) == ["arm64","x86_64"]
' "$gh_manifest" >/dev/null || php_darwin_die 'publisher created an invalid release manifest'
manifest_asset=$(jq -er '.assets[0].name' "$gh_manifest") || \
  php_darwin_die 'could not select a published manifest asset'
manifest_values=$(php_darwin_validate_release_manifest "$gh_manifest" "$version" stable "$manifest_asset") || \
  php_darwin_die 'published stable manifest did not pass shared validation'
IFS=$'\t' read -r manifest_hash manifest_commit manifest_php_src_commit manifest_semver manifest_source_hash \
  manifest_download_asset manifest_extensions_commit \
  <<< "$manifest_values" || php_darwin_die 'could not parse the published stable manifest'
[ "$manifest_hash" = "$(jq -er --arg asset "$manifest_asset" \
  '.assets[] | select(.name == $asset) | .sha256' "$gh_manifest")" ] && \
  [ "$manifest_commit" = "$source_commit" ] && [ "$manifest_php_src_commit" = - ] && \
  [ "$manifest_semver" = "$semver" ] && \
  [ "$manifest_source_hash" = "$source_hash" ] && \
  [ "$manifest_download_asset" = "$(php_darwin_download_asset "$manifest_asset" "$manifest_hash")" ] && \
  [ "$manifest_extensions_commit" = "$extension_source_commit" ] || \
  php_darwin_die 'stable manifest fields were not preserved across parsing'

legacy_manifest="$work_dir/legacy-stable-manifest.json"
jq '.php_src_commit=null' "$gh_manifest" > "$legacy_manifest" || \
  php_darwin_die 'could not create a legacy stable manifest fixture'
legacy_manifest_values=$(php_darwin_validate_release_manifest \
  "$legacy_manifest" "$version" stable "$manifest_asset") || \
  php_darwin_die 'legacy stable manifest did not pass compatibility validation'
[ "$legacy_manifest_values" = "$manifest_values" ] || \
  php_darwin_die 'legacy stable manifest fields were not normalized'
legacy_asset_manifest="$work_dir/legacy-asset-manifest.json"
jq 'del(.assets[].download)' "$gh_manifest" > "$legacy_asset_manifest" || \
  php_darwin_die 'could not create a legacy release-asset fixture'
legacy_asset_values=$(php_darwin_validate_release_manifest \
  "$legacy_asset_manifest" "$version" stable "$manifest_asset") || \
  php_darwin_die 'legacy release asset names did not pass compatibility validation'
IFS=$'\t' read -r _ _ _ _ _ legacy_asset_download _ <<< "$legacy_asset_values" || \
  php_darwin_die 'could not parse legacy release asset metadata'
[ "$legacy_asset_download" = "$manifest_asset" ] || \
  php_darwin_die 'legacy release asset name was not preserved'
legacy_arm_manifest="$work_dir/legacy-arm-manifest.json"
jq '.assets |= map(select(.architecture == "arm64"))' "$legacy_asset_manifest" > "$legacy_arm_manifest" || \
  php_darwin_die 'could not create an ARM64-only manifest fixture'
legacy_arm_values=$(php_darwin_validate_release_manifest \
  "$legacy_arm_manifest" "$version" stable "$manifest_asset") || \
  php_darwin_die 'ARM64-only manifest did not pass compatibility validation'
IFS=$'\t' read -r _ _ _ _ _ legacy_arm_download _ <<< "$legacy_arm_values" || \
  php_darwin_die 'could not parse ARM64-only release metadata'
[ "$legacy_arm_download" = "$manifest_asset" ] || \
  php_darwin_die 'ARM64-only manifest did not select the ARM64 archive'
legacy_intel_asset=$(jq -er '[.assets[] | select(.architecture == "x86_64")][0].name' \
  "$gh_manifest") || php_darwin_die 'could not select an Intel fixture asset'
if php_darwin_validate_release_manifest \
  "$legacy_arm_manifest" "$version" stable "$legacy_intel_asset" >/dev/null 2>&1; then
  php_darwin_die 'ARM64-only manifest selected a missing Intel archive'
fi
legacy_extension_manifest="$work_dir/legacy-extension-manifest.json"
jq 'del(.homebrew_extensions_commit)' "$gh_manifest" > "$legacy_extension_manifest" || \
  php_darwin_die 'could not create a legacy extension manifest fixture'
legacy_extension_values=$(php_darwin_validate_release_manifest \
  "$legacy_extension_manifest" "$version" stable "$manifest_asset") || \
  php_darwin_die 'legacy manifest without an extension commit was rejected'
IFS=$'\t' read -r _ _ _ _ _ _ legacy_extensions_commit <<< "$legacy_extension_values" || \
  php_darwin_die 'could not parse legacy extension manifest metadata'
[ "$legacy_extensions_commit" = - ] || \
  php_darwin_die 'legacy extension manifest commit was not normalized'
legacy_extensions_hash_manifest="$work_dir/legacy-extensions-hash-manifest.json"
jq 'del(.extensions_source_hash)' "$gh_manifest" > "$legacy_extensions_hash_manifest" || \
  php_darwin_die 'could not create a legacy extension source hash manifest fixture'
php_darwin_validate_release_manifest "$legacy_extensions_hash_manifest" "$version" stable \
  "$manifest_asset" >/dev/null || \
  php_darwin_die 'legacy manifest without an extension source hash was rejected'
missing_commit_manifest="$work_dir/missing-commit-stable-manifest.json"
jq 'del(.php_src_commit)' "$gh_manifest" > "$missing_commit_manifest" || \
  php_darwin_die 'could not create a missing-commit stable manifest fixture'
if php_darwin_validate_release_manifest \
  "$missing_commit_manifest" "$version" stable "$manifest_asset" >/dev/null 2>&1; then
  php_darwin_die 'stable manifest validation accepted a missing PHP source commit field'
fi

legacy_metadata="$work_dir/legacy-stable-metadata.json"
jq '.php_src_commit=null' "$metadata" > "$legacy_metadata" || \
  php_darwin_die 'could not create a legacy stable metadata fixture'
legacy_build=$(jq -er '.build' "$legacy_metadata") || php_darwin_die 'could not read the legacy build'
legacy_ts=$(jq -er '.thread_safety' "$legacy_metadata") || php_darwin_die 'could not read legacy thread safety'
legacy_arch=$(jq -er '.architecture' "$legacy_metadata") || php_darwin_die 'could not read the legacy architecture'
legacy_prefix=$(php_darwin_platform_value "$legacy_arch" brew_prefix) || \
  php_darwin_die 'could not read the configured legacy prefix'
legacy_minimum=$(php_darwin_platform_value "$legacy_arch" minimum_macos) || \
  php_darwin_die 'could not read the configured minimum macOS'
legacy_platform=$(php_darwin_platform_value "$legacy_arch" platform_key) || \
  php_darwin_die 'could not read the configured legacy platform'
php_darwin_validate_cache_metadata "$legacy_metadata" "$version" "$legacy_build" "$legacy_ts" \
  "$legacy_arch" "$legacy_prefix" 26 "$source_commit" '' "$(php_darwin_package_config current_version)" \
  "$(php_darwin_package_config tap_snapshot)" "$legacy_minimum" "$legacy_platform" \
  "$extension_source_commit" >/dev/null || \
  php_darwin_die 'legacy stable cache metadata did not pass compatibility validation'
missing_default_metadata="$work_dir/missing-default-php-metadata.json"
jq '.links=[]' "$legacy_metadata" > "$missing_default_metadata" || \
  php_darwin_die 'could not create a missing default PHP link fixture'
if php_darwin_validate_cache_metadata "$missing_default_metadata" "$version" "$legacy_build" "$legacy_ts" \
  "$legacy_arch" "$legacy_prefix" 26 "$source_commit" '' "$(php_darwin_package_config current_version)" \
  "$(php_darwin_package_config tap_snapshot)" "$legacy_minimum" "$legacy_platform" \
  "$extension_source_commit" >/dev/null 2>&1; then
  php_darwin_die 'cache metadata accepted a missing default PHP link'
fi
wrong_default_metadata="$work_dir/wrong-default-php-metadata.json"
jq '.links[0].target="../Cellar/php@8.4/8.4.0/bin/php"' "$legacy_metadata" > "$wrong_default_metadata" || \
  php_darwin_die 'could not create a wrong default PHP link fixture'
if php_darwin_validate_cache_metadata "$wrong_default_metadata" "$version" "$legacy_build" "$legacy_ts" \
  "$legacy_arch" "$legacy_prefix" 26 "$source_commit" '' "$(php_darwin_package_config current_version)" \
  "$(php_darwin_package_config tap_snapshot)" "$legacy_minimum" "$legacy_platform" \
  "$extension_source_commit" >/dev/null 2>&1; then
  php_darwin_die 'cache metadata accepted another formula as the default PHP link'
fi
legacy_trust_metadata="$work_dir/legacy-trust-metadata.json"
jq 'del(.tap_formulae)' "$legacy_metadata" > "$legacy_trust_metadata" || \
  php_darwin_die 'could not create legacy formula-trust metadata'
php_darwin_validate_cache_metadata "$legacy_trust_metadata" "$version" "$legacy_build" "$legacy_ts" \
  "$legacy_arch" "$legacy_prefix" 26 "$source_commit" '' "$(php_darwin_package_config current_version)" \
  "$(php_darwin_package_config tap_snapshot)" "$legacy_minimum" "$legacy_platform" \
  "$extension_source_commit" >/dev/null || \
  php_darwin_die 'legacy cache metadata without custom-tap formulae was rejected'
invalid_trust_metadata="$work_dir/invalid-trust-metadata.json"
jq '.tap_formulae=["not-in-packages"]' "$legacy_metadata" > "$invalid_trust_metadata" || \
  php_darwin_die 'could not create invalid formula-trust metadata'
if php_darwin_validate_cache_metadata "$invalid_trust_metadata" "$version" "$legacy_build" "$legacy_ts" \
  "$legacy_arch" "$legacy_prefix" 26 "$source_commit" '' "$(php_darwin_package_config current_version)" \
  "$(php_darwin_package_config tap_snapshot)" "$legacy_minimum" "$legacy_platform" \
  "$extension_source_commit" >/dev/null 2>&1; then
  php_darwin_die 'cache metadata accepted a custom-tap formula outside its package set'
fi
if php_darwin_validate_cache_metadata "$legacy_metadata" "$version" "$legacy_build" "$legacy_ts" \
  "$legacy_arch" "$legacy_prefix" 26 "$source_commit" '' "$(php_darwin_package_config current_version)" \
  "$(php_darwin_package_config tap_snapshot)" "$((legacy_minimum + 1))" "$legacy_platform" \
  "$extension_source_commit" \
  >/dev/null 2>&1; then
  php_darwin_die 'legacy stable cache metadata ignored the configured minimum macOS'
fi
missing_commit_metadata="$work_dir/missing-commit-stable-metadata.json"
jq 'del(.php_src_commit)' "$legacy_metadata" > "$missing_commit_metadata" || \
  php_darwin_die 'could not create a missing-commit stable metadata fixture'
if php_darwin_validate_cache_metadata "$missing_commit_metadata" "$version" "$legacy_build" "$legacy_ts" \
  "$legacy_arch" "$legacy_prefix" 26 "$source_commit" '' "$(php_darwin_package_config current_version)" \
  "$(php_darwin_package_config tap_snapshot)" "$legacy_minimum" "$legacy_platform" \
  "$extension_source_commit" >/dev/null 2>&1; then
  php_darwin_die 'stable cache metadata validation accepted a missing PHP source commit field'
fi
legacy_extension_metadata="$work_dir/legacy-extension-metadata.json"
jq 'del(.homebrew_extensions_commit,.extensions)' "$legacy_metadata" > "$legacy_extension_metadata" || \
  php_darwin_die 'could not create legacy extension metadata'
php_darwin_validate_cache_metadata "$legacy_extension_metadata" "$version" "$legacy_build" "$legacy_ts" \
  "$legacy_arch" "$legacy_prefix" 26 "$source_commit" '' "$(php_darwin_package_config current_version)" \
  "$(php_darwin_package_config tap_snapshot)" "$legacy_minimum" "$legacy_platform" >/dev/null || \
  php_darwin_die 'legacy cache metadata without extension fields was rejected'
if php_darwin_validate_cache_metadata "$legacy_extension_metadata" "$version" "$legacy_build" "$legacy_ts" \
  "$legacy_arch" "$legacy_prefix" 26 "$source_commit" '' "$(php_darwin_package_config current_version)" \
  "$(php_darwin_package_config tap_snapshot)" "$legacy_minimum" "$legacy_platform" \
  "$extension_source_commit" >/dev/null 2>&1; then
  php_darwin_die 'legacy cache metadata satisfied an expected extension commit'
fi
grep -Fq '"php_version": "7.0"' "$gh_installer" || \
  php_darwin_die 'published installer did not embed the matching release manifest'
installer_download=$(jq -er '.assets[0].download' "$gh_manifest") || \
  php_darwin_die 'could not select an immutable installer asset'
grep -Fq "\"download\": \"$installer_download\"" "$gh_installer" || \
  php_darwin_die 'published installer did not embed the immutable release asset'

# A subsequent publish keeps the generation referenced by the previous
# installer, uploads a new immutable generation, and removes older immutable
# assets plus the retired mutable and Intel archive names.
previous_generation="$work_dir/previous-generation"
previous_generation_json="$work_dir/previous-generation-assets.json"
mkdir -p "$previous_generation" || php_darwin_die 'could not create immutable release fixtures'
cp "$gh_manifest" "$previous_generation/php-$version-manifest.json" || \
  php_darwin_die 'could not preserve the previous release manifest fixture'
cp "$gh_installer" "$previous_generation/install.sh" || \
  php_darwin_die 'could not preserve the previous release installer fixture'
while IFS= read -r previous_download; do
  printf 'previous immutable archive\n' > "$previous_generation/$previous_download" || exit 1
  printf 'previous immutable checksum\n' > "$previous_generation/$previous_download.sha256" || exit 1
done < <(jq -r '.assets[].download' "$gh_manifest")
stale_hash=$(printf 'f%.0s' {1..64})
stale_asset="php_7.0-nts-release+darwin_arm64.$stale_hash.tar.zst"
printf 'stale immutable archive\n' > "$previous_generation/$stale_asset" || exit 1
printf 'stale immutable checksum\n' > "$previous_generation/$stale_asset.sha256" || exit 1
plain_asset="php_7.0-nts-release+darwin_arm64.tar.zst"
intel_asset="php_7.0-nts-release+darwin_x86_64.tar.zst"
printf 'retired mutable archive\n' > "$previous_generation/$plain_asset" || exit 1
printf 'retired Intel archive\n' > "$previous_generation/$intel_asset" || exit 1
php_darwin_test_release_assets "$previous_generation" "$previous_generation_json" || \
  php_darwin_die 'could not inventory the previous release generation'
while IFS= read -r archive_fixture; do
  printf 'next generation\n' >> "$archive_fixture" || exit 1
  archive_fixture_hash=$(php_darwin_sha256 "$archive_fixture") || exit 1
  printf '%s  %s\n' "$archive_fixture_hash" "${archive_fixture##*/}" > "$archive_fixture.sha256" || exit 1
done < <(find "$builds_dir" -type f -name '*.tar.zst' -print)
: > "$gh_log" || php_darwin_die 'could not reset the immutable publish log'
GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$previous_generation_json" \
  GH_PREVIOUS_ASSETS="$previous_generation" PHP_VERSION="$version" \
  PATH="$fake_bin:$PATH" bash "$script_dir/../../release/publish.sh" "$builds_dir" >/dev/null || \
  php_darwin_die 'immutable release replacement fixture failed'
grep -Fxq "release delete-asset php-7.0 $stale_asset --yes --repo shivammathur/php-darwin" "$gh_log" || \
  php_darwin_die 'publisher did not remove a stale immutable archive'
grep -Fxq "release delete-asset php-7.0 $stale_asset.sha256 --yes --repo shivammathur/php-darwin" "$gh_log" || \
  php_darwin_die 'publisher did not remove a stale immutable checksum'
grep -Fxq "release delete-asset php-7.0 $plain_asset --yes --repo shivammathur/php-darwin" "$gh_log" || \
  php_darwin_die 'publisher did not retire the mutable archive name'
grep -Fxq "release delete-asset php-7.0 $intel_asset --yes --repo shivammathur/php-darwin" "$gh_log" || \
  php_darwin_die 'publisher did not retire the mutable Intel archive name'
while IFS= read -r previous_download; do
  ! grep -Fq "release delete-asset php-7.0 $previous_download " "$gh_log" || \
    php_darwin_die 'publisher removed the previous installer generation'
done < <(jq -r '.assets[].download' "$previous_generation/php-$version-manifest.json")

# A malformed prior manifest cannot authorize deletion of any immutable asset.
invalid_previous_generation="$work_dir/invalid-previous-generation"
invalid_previous_json="$work_dir/invalid-previous-assets.json"
cp -R "$previous_generation" "$invalid_previous_generation" || \
  php_darwin_die 'could not create an invalid previous release fixture'
jq 'del(.homebrew_php_commit)' "$previous_generation/php-$version-manifest.json" \
  > "$invalid_previous_generation/php-$version-manifest.json" || \
  php_darwin_die 'could not invalidate the previous release manifest fixture'
php_darwin_test_release_assets "$invalid_previous_generation" "$invalid_previous_json" || \
  php_darwin_die 'could not inventory the invalid previous release fixture'
: > "$gh_log" || php_darwin_die 'could not reset the invalid-manifest publish log'
GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$invalid_previous_json" \
  GH_PREVIOUS_ASSETS="$invalid_previous_generation" PHP_VERSION="$version" \
  PATH="$fake_bin:$PATH" bash "$script_dir/../../release/publish.sh" "$builds_dir" >/dev/null || \
  php_darwin_die 'publish with an invalid previous manifest fixture failed'
! grep -Fq "release delete-asset php-7.0 $stale_asset " "$gh_log" || \
  php_darwin_die 'publisher deleted immutable assets using an invalid previous manifest'

# Even an invalid previous manifest remains a rollback source until the new
# manifest commit point succeeds.
invalid_manifest_upload_marker="$work_dir/invalid-manifest-upload.marker"
: > "$gh_log" || php_darwin_die 'could not reset the invalid-manifest rollback log'
if GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$invalid_previous_json" \
  GH_PREVIOUS_ASSETS="$invalid_previous_generation" \
  GH_FAIL_UPLOAD_ATTEMPTS=3 GH_FAIL_UPLOAD_ONCE_MATCH='php-7.0-manifest.json' \
  GH_FAIL_UPLOAD_ONCE_MARKER="$invalid_manifest_upload_marker" \
  PHP_VERSION="$version" PATH="$fake_bin:$PATH" bash "$script_dir/../../release/publish.sh" "$builds_dir" \
  >/dev/null 2>&1; then
  php_darwin_die 'publish unexpectedly committed over an invalid previous manifest fixture'
fi
grep -Eq '^release upload php-7\.0 .*/previous-assets/.*php-7\.0-manifest\.json.*--clobber' \
  "$gh_log" || php_darwin_die 'publisher discarded an invalid manifest needed for rollback'

# A complete generation is idempotent and needs no archive upload.
current_generation="$work_dir/current-generation"
current_generation_json="$work_dir/current-generation-assets.json"
mkdir -p "$current_generation" || php_darwin_die 'could not create the current generation fixture'
cp "$gh_manifest" "$current_generation/php-$version-manifest.json" || exit 1
cp "$gh_installer" "$current_generation/install.sh" || exit 1
while IFS= read -r archive_fixture; do
  logical_name=${archive_fixture##*/}
  archive_fixture_hash=$(php_darwin_sha256 "$archive_fixture") || exit 1
  immutable_name=$(php_darwin_download_asset "$logical_name" "$archive_fixture_hash") || exit 1
  cp "$archive_fixture" "$current_generation/$immutable_name" || exit 1
  printf '%s  %s\n' "$archive_fixture_hash" "$immutable_name" \
    > "$current_generation/$immutable_name.sha256" || exit 1
done < <(find "$builds_dir" -type f -name '*.tar.zst' -print)
php_darwin_test_release_assets "$current_generation" "$current_generation_json" || \
  php_darwin_die 'could not inventory the current release generation'
: > "$gh_log" || php_darwin_die 'could not reset the idempotent publish log'
GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$current_generation_json" \
  GH_PREVIOUS_ASSETS="$current_generation" PHP_VERSION="$version" PATH="$fake_bin:$PATH" \
  bash "$script_dir/../../release/publish.sh" "$builds_dir" >/dev/null || \
  php_darwin_die 'idempotent release publish fixture failed'
! grep -Eq '^release upload php-7\.0 .*\.[0-9a-f]{64}\.tar\.zst' "$gh_log" || \
  php_darwin_die 'idempotent publisher re-uploaded immutable release assets'

# GitHub may not have computed a digest for an uploaded immutable asset yet.
# Its empty digest is unknown, not evidence that the asset is corrupt.
unknown_digest_json="$work_dir/unknown-digest-assets.json"
unknown_digest_asset=$(jq -er '[.assets[] | select(.name | test("\\.tar\\.zst$"))][0].name' \
  "$current_generation_json") || exit 1
unknown_digest_api=$(jq -er --arg name "$unknown_digest_asset" \
  '.assets[] | select(.name == $name) | .apiUrl' "$current_generation_json") || exit 1
jq --arg name "$unknown_digest_asset" \
  '.assets |= map(if .name == $name then .digest="" else . end)' \
  "$current_generation_json" > "$unknown_digest_json" || exit 1
: > "$gh_log" || php_darwin_die 'could not reset the unknown-digest publish log'
GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$unknown_digest_json" \
  GH_PREVIOUS_ASSETS="$current_generation" PHP_VERSION="$version" PATH="$fake_bin:$PATH" \
  bash "$script_dir/../../release/publish.sh" "$builds_dir" >/dev/null || \
  php_darwin_die 'publisher rejected an uploaded immutable asset with an unknown digest'
! grep -Fq "api --method PATCH $unknown_digest_api " "$gh_log" || \
  php_darwin_die 'publisher quarantined an uploaded immutable asset with an unknown digest'

# Quarantine names left by an interrupted earlier repair are removed after a
# successful manifest commit instead of accumulating indefinitely.
quarantine_generation="$work_dir/quarantine-generation"
quarantine_assets_json="$work_dir/quarantine-assets.json"
cp -R "$current_generation" "$quarantine_generation" || exit 1
quarantine_name="$unknown_digest_asset.invalid.999999"
printf 'retired quarantine fixture\n' > "$quarantine_generation/$quarantine_name" || exit 1
php_darwin_test_release_assets "$quarantine_generation" "$quarantine_assets_json" || exit 1
: > "$gh_log" || php_darwin_die 'could not reset the quarantine cleanup log'
GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$quarantine_assets_json" \
  GH_PREVIOUS_ASSETS="$quarantine_generation" PHP_VERSION="$version" PATH="$fake_bin:$PATH" \
  bash "$script_dir/../../release/publish.sh" "$builds_dir" >/dev/null || \
  php_darwin_die 'publisher could not recover an existing quarantined asset'
grep -Fxq "release delete-asset php-7.0 $quarantine_name --yes --repo shivammathur/php-darwin" \
  "$gh_log" || php_darwin_die 'publisher did not classify and remove a quarantined asset'

# A corrupt partial immutable asset is quarantined, repaired, and only then removed.
ghost_assets_json="$work_dir/ghost-assets.json"
ghost_asset=$(jq -er '.assets[0].download' "$gh_manifest") || exit 1
ghost_api_url=$(jq -er --arg name "$ghost_asset" '.assets[] | select(.name == $name) | .apiUrl' \
  "$current_generation_json") || exit 1
ghost_invalid="$ghost_asset.invalid.${ghost_api_url##*/}"
jq --arg name "$ghost_asset" --arg digest "sha256:$(printf '0%.0s' {1..64})" '
  .assets |= map(if .name == $name then .digest=$digest else . end)
' "$current_generation_json" > "$ghost_assets_json" || exit 1
: > "$gh_log" || php_darwin_die 'could not reset the ghost-asset publish log'
GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$ghost_assets_json" \
  GH_PREVIOUS_ASSETS="$current_generation" PHP_VERSION="$version" PATH="$fake_bin:$PATH" \
  bash "$script_dir/../../release/publish.sh" "$builds_dir" >/dev/null || \
  php_darwin_die 'partial immutable release retry fixture failed'
grep -Fq "api --method PATCH $ghost_api_url -f name=$ghost_invalid" \
  "$gh_log" || php_darwin_die 'publisher did not quarantine the corrupt immutable asset'
grep -F 'release upload php-7.0 ' "$gh_log" | \
  grep -Fq "/$ghost_asset --repo shivammathur/php-darwin" || \
  php_darwin_die 'publisher did not repair the corrupt immutable asset'
grep -Fxq "release delete-asset php-7.0 $ghost_invalid --yes --repo shivammathur/php-darwin" \
  "$gh_log" || php_darwin_die 'publisher did not remove the quarantined immutable asset'

# A failed corrupt-asset repair restores the original public name.
: > "$gh_log" || php_darwin_die 'could not reset the failed repair log'
if GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$ghost_assets_json" \
  GH_PREVIOUS_ASSETS="$current_generation" GH_FAIL_UPLOAD_MATCH="$ghost_asset" \
  PHP_VERSION="$version" PATH="$fake_bin:$PATH" bash "$script_dir/../../release/publish.sh" "$builds_dir" \
  >/dev/null 2>&1; then
  php_darwin_die 'publisher accepted a failed corrupt immutable-asset repair'
fi
grep -Fq "api --method PATCH $ghost_api_url -f name=$ghost_asset" "$gh_log" || \
  php_darwin_die 'publisher did not restore the corrupt immutable asset name after upload failure'

# An existing release with zero assets is recoverable without a backup download.
empty_release="$work_dir/empty-release"
empty_assets_json="$work_dir/empty-assets.json"
mkdir -p "$empty_release" || exit 1
printf '{"assets":[]}\n' > "$empty_assets_json" || exit 1
: > "$gh_log" || php_darwin_die 'could not reset the empty-release publish log'
GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$empty_assets_json" \
  GH_PREVIOUS_ASSETS="$empty_release" PHP_VERSION="$version" PATH="$fake_bin:$PATH" \
  bash "$script_dir/../../release/publish.sh" "$builds_dir" >/dev/null || \
  php_darwin_die 'empty release recovery fixture failed'
! grep -Fq 'release download ' "$gh_log" || \
  php_darwin_die 'publisher tried to download assets from an empty release'

# Garbage-collection failure after the manifest commit cannot roll back it.
postcommit_generation="$work_dir/postcommit-generation"
postcommit_assets_json="$work_dir/postcommit-assets.json"
cp -R "$current_generation" "$postcommit_generation" || exit 1
printf 'postcommit stale archive\n' > "$postcommit_generation/$stale_asset" || exit 1
php_darwin_test_release_assets "$postcommit_generation" "$postcommit_assets_json" || exit 1
: > "$gh_log" || php_darwin_die 'could not reset the postcommit publish log'
GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$postcommit_assets_json" \
  GH_PREVIOUS_ASSETS="$postcommit_generation" GH_FAIL_DELETE_MATCH="$stale_asset" \
  PHP_VERSION="$version" PATH="$fake_bin:$PATH" bash "$script_dir/../../release/publish.sh" "$builds_dir" \
  >/dev/null || php_darwin_die 'postcommit cleanup failure rolled back the release'
! grep -Eq '^release upload php-7\.0 .*/previous-assets/' "$gh_log" || \
  php_darwin_die 'postcommit cleanup failure restored the previous release'

# Retired mutable and Intel names are security-sensitive and fail the publish
# after the manifest commit if GitHub does not remove them.
: > "$gh_log" || php_darwin_die 'could not reset the retired-asset failure log'
if GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$previous_generation_json" \
  GH_PREVIOUS_ASSETS="$previous_generation" GH_FAIL_DELETE_MATCH="$plain_asset" \
  PHP_VERSION="$version" PATH="$fake_bin:$PATH" bash "$script_dir/../../release/publish.sh" "$builds_dir" \
  >/dev/null 2>&1; then
  php_darwin_die 'publisher ignored a retired mutable release asset deletion failure'
fi
! grep -Eq '^release upload php-7\.0 .*/previous-assets/' "$gh_log" || \
  php_darwin_die 'retired-asset cleanup failure rolled back a committed release'

if PHP_VERSION=7.1 HOMEBREW_PHP_COMMIT="$source_commit" PATH="$fake_bin:$PATH" \
  bash "$script_dir/../../release/publish.sh" "$builds_dir" >/dev/null 2>&1; then
  php_darwin_die 'publish validation accepted a different requested PHP version'
fi

checksum_fixture=$(find "$builds_dir" -type f -name '*.sha256' -print -quit)
[ -f "$checksum_fixture" ] || php_darwin_die 'publish checksum fixture is missing'
mv "$checksum_fixture" "$checksum_fixture.missing" || php_darwin_die 'could not hide the checksum fixture'
if HOMEBREW_PHP_COMMIT="$source_commit" PATH="$fake_bin:$PATH" \
  bash "$script_dir/../../release/publish.sh" "$builds_dir" >/dev/null 2>&1; then
  php_darwin_die 'publish validation accepted an archive without a checksum'
fi

mv "$checksum_fixture.missing" "$checksum_fixture" || \
  php_darwin_die 'could not restore the checksum fixture'

# A complete mutable asset must be backed up before any release mutation.
: > "$gh_log" || php_darwin_die 'could not reset the backup recovery log'
if GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$current_generation_json" \
  GH_PREVIOUS_ASSETS="$current_generation" GH_FAIL_DOWNLOAD_MATCH=install.sh \
  PHP_VERSION="$version" PATH="$fake_bin:$PATH" bash "$script_dir/../../release/publish.sh" "$builds_dir" \
  >/dev/null 2>&1; then
  php_darwin_die 'publisher mutated a release without a recoverable mutable-asset backup'
fi
! grep -Fq 'release upload ' "$gh_log" || \
  php_darwin_die 'publisher uploaded assets after a mutable-asset backup failure'

# An incomplete mutable asset is not a valid rollback source and self-heals.
incomplete_mutable_json="$work_dir/incomplete-mutable-assets.json"
jq '.assets |= map(if .name == "install.sh" then .state="new" | .digest="" else . end)' \
  "$current_generation_json" > "$incomplete_mutable_json" || exit 1
: > "$gh_log" || php_darwin_die 'could not reset the incomplete mutable-asset log'
GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$incomplete_mutable_json" \
  GH_PREVIOUS_ASSETS="$current_generation" PHP_VERSION="$version" PATH="$fake_bin:$PATH" \
  bash "$script_dir/../../release/publish.sh" "$builds_dir" >/dev/null || \
  php_darwin_die 'publisher did not repair an incomplete mutable release asset'
! grep -Fq 'release download php-7.0 --pattern install.sh ' "$gh_log" || \
  php_darwin_die 'publisher used an incomplete mutable asset as a rollback source'

# A failure at the manifest commit point restores the previous mutable files.
upload_once_marker="$work_dir/upload-once.marker"
: > "$gh_log" || php_darwin_die 'could not reset the publish rollback log'
if GH_RELEASE_EXISTS=true GH_RELEASE_ASSETS_JSON="$current_generation_json" \
  GH_PREVIOUS_ASSETS="$current_generation" GH_FAIL_UPLOAD_ATTEMPTS=3 GH_FAIL_UPLOAD_ONCE_MATCH='php-7.0-manifest.json' \
  GH_FAIL_UPLOAD_ONCE_MARKER="$upload_once_marker" \
  PHP_VERSION="$version" PATH="$fake_bin:$PATH" bash "$script_dir/../../release/publish.sh" "$builds_dir" \
  >/dev/null 2>&1; then
  php_darwin_die 'publish rollback fixture unexpectedly succeeded'
fi
grep -Eq '^release download php-7\.0 --pattern install\.sh --clobber --dir .* --repo shivammathur/php-darwin$' \
  "$gh_log" || php_darwin_die 'publisher did not back up the existing installer'
grep -Eq '^release download php-7\.0 --pattern php-7\.0-manifest\.json --clobber --dir .* --repo shivammathur/php-darwin$' \
  "$gh_log" || php_darwin_die 'publisher did not back up the existing manifest'
tail -n 1 "$gh_log" | grep -Eq \
  '^release upload php-7\.0 .*/previous-assets/(install\.sh|php-7\.0-manifest\.json) .*/previous-assets/(install\.sh|php-7\.0-manifest\.json) --clobber --repo shivammathur/php-darwin$' || \
  php_darwin_die 'publisher did not restore the previous mutable assets after an upload failure'
printf 'Release publish validation passed\n'
