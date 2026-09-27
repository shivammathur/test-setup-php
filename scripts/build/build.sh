#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

[ "${GITHUB_ACTIONS:-}" = true ] || [ "${PHP_DARWIN_ALLOW_LOCAL_BUILD:-}" = true ] || \
  php_darwin_die 'build.sh may only clean Homebrew on an Actions runner (set PHP_DARWIN_ALLOW_LOCAL_BUILD=true to override)'

stage=${1:-all}
version=${PHP_VERSION:?}
build=${BUILD:?}
ts=${TS:?}
arch=$(php_darwin_normalize_arch "${ARCH:?}") || exit 1
source_commit=${HOMEBREW_PHP_COMMIT:?}
extension_source_commit=${HOMEBREW_EXTENSIONS_COMMIT:?}
formula=$(php_darwin_formula "$version" "$build" "$ts") || exit 1
requested_formula=$(php_darwin_requested_formula "$version" "$build" "$ts") || exit 1
config_id=$(php_darwin_config_id "$version" "$build" "$ts") || exit 1
pear_path=$(php_darwin_pear_path "$version" "$formula") || exit 1
expected_prefix=$(php_darwin_expected_prefix "$arch") || php_darwin_die "Homebrew prefix is not configured for $arch"
brew_prefix=$(brew --prefix)
tap=$(php_darwin_package_config tap) || exit 1
minimum_macos=$(php_darwin_platform_value "$arch" minimum_macos) || \
  php_darwin_die "minimum macOS is not configured for $arch"
platform_key=$(php_darwin_platform_value "$arch" platform_key) || \
  php_darwin_die "platform key is not configured for $arch"
work_dir="${RUNNER_TEMP:-/tmp}/php-darwin-build"
before_manifest="$work_dir/before.tsv"
after_manifest="$work_dir/after.tsv"
changed_manifest="$work_dir/changed.tsv"
archive_paths="$work_dir/archive-paths.txt"
packages_file="$work_dir/packages.tsv"
preinstalled_formulae="$work_dir/preinstalled-formulae.txt"
cleanup_formulae="$work_dir/cleanup-formulae.txt"
installed_formulae_file="$work_dir/installed-formulae.txt"
installed_formulae_raw="$work_dir/installed-formulae-raw.txt"
packages_to_archive="$work_dir/packages-to-archive.txt"
php_dependencies="$work_dir/php-dependencies.txt"
raw_dependencies="$work_dir/raw-dependencies.txt"
runtime_dependencies="$work_dir/runtime-dependencies.txt"
raw_runtime_dependencies="$work_dir/raw-runtime-dependencies.txt"
formulae_to_remove="$work_dir/formulae-to-remove.txt"
preserved_formulae_file="$work_dir/preserved-formulae.txt"
preserved_versions_file="$work_dir/preserved-versions.txt"
pinned_formulae_file="$work_dir/pinned-formulae.txt"
added_pins_file="$work_dir/added-pins.txt"
reuse_dir="${RUNNER_TEMP:-/tmp}/php-darwin-reuse"
reuse_baseline_manifest="$reuse_dir/before.tsv"
snapshot_paths="$script_dir/../../conf/snapshot-paths"
archive_roots="$script_dir/../../conf/archive-paths"
cached_extensions_file="$work_dir/cached-extension-paths.txt"

[ "$(uname -s)" = Darwin ] || php_darwin_die 'builds require macOS'
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || php_darwin_die 'invalid homebrew-php source commit'
[[ "$extension_source_commit" =~ ^[0-9a-f]{40}$ ]] || \
  php_darwin_die 'invalid homebrew-extensions source commit'
runner_arch=$(php_darwin_normalize_arch "$(uname -m)") || exit 1
[ "$runner_arch" = "$arch" ] || php_darwin_die 'runner architecture does not match the matrix'
[ "$brew_prefix" = "$expected_prefix" ] || php_darwin_die "expected Homebrew at $expected_prefix, found $brew_prefix"
php_darwin_configure_homebrew_environment
export HOMEBREW_VERBOSE=1 HOMEBREW_VERBOSE_USING_DOTS=0

prepare_homebrew() {
  local formula_file
  local tap_path

  brew tap "$tap" || php_darwin_die "could not tap $tap"
  brew trust "$tap" || php_darwin_die "could not trust $tap"
  tap_path=$(brew --repository "$tap") || php_darwin_die "could not resolve the $tap repository"
  if ! git -C "$tap_path" cat-file -e "$source_commit^{commit}" 2>/dev/null; then
    git -C "$tap_path" fetch --depth=1 origin "$source_commit" || \
      php_darwin_die "could not fetch homebrew-php commit $source_commit"
  fi
  git -C "$tap_path" checkout --detach "$source_commit" || \
    php_darwin_die "could not pin homebrew-php at $source_commit"
  formula_file=$(brew formula "$tap/$requested_formula") || \
    php_darwin_die "could not resolve $tap/$requested_formula"
  [ -f "$formula_file" ] || php_darwin_die "formula file not found: $formula_file"
}

clean_homebrew() {
  local dependency_formula
  local dependency_formulae=()
  local installed_formula
  local installed_formulae=()
  local pipeline_status
  local preserved_formula
  local preserved_formulae=()
  local preserved_formulae_to_pin=()
  local preserved_count
  local removed_count

  mkdir -p "$work_dir" || php_darwin_die 'could not create the build directory'
  find "$work_dir" -mindepth 1 -delete || php_darwin_die 'could not clean the build directory'

  # Preserve Homebrew's complete dependency graph for the pinned PHP formula
  # and the tools used after cleanup to package the archive.
  brew list --formula --versions > "$cleanup_formulae" || \
    php_darwin_die 'could not record preinstalled Homebrew formula versions'
  LC_ALL=C sort -u "$cleanup_formulae" -o "$cleanup_formulae" || \
    php_darwin_die 'could not sort preinstalled Homebrew formula versions'
  brew deps --formula --union --include-build --include-implicit \
    "$tap/$requested_formula" jq zstd > "$raw_dependencies" || \
    php_darwin_die "could not resolve dependencies for $requested_formula and the packaging tools"
  printf 'jq\nzstd\n' >> "$raw_dependencies" || \
    php_darwin_die 'could not include Homebrew packaging tools'
  LC_ALL=C sort -u "$raw_dependencies" -o "$raw_dependencies" || \
    php_darwin_die 'could not sort the Homebrew dependency list'
  awk 'NF && (NF != 1 || $1 !~ /^([A-Za-z0-9@+._-]+\/){0,2}[A-Za-z0-9@+._-]+$/) { exit 1 }' \
    "$raw_dependencies" || \
    php_darwin_die "Homebrew returned an invalid dependency for $requested_formula"
  while IFS= read -r dependency_formula; do
    [ -n "$dependency_formula" ] && dependency_formulae+=("$dependency_formula")
  done < "$raw_dependencies"
  [ "${#dependency_formulae[@]}" -gt 0 ] || \
    php_darwin_die "Homebrew returned no dependencies for $requested_formula"
  brew info --json=v2 --formula "${dependency_formulae[@]}" > "$work_dir/dependency-info.json" || \
    php_darwin_die 'could not inspect current dependency versions'
  bash "$script_dir/canonicalize-formulae.sh" < "$work_dir/dependency-info.json" > "$php_dependencies" || \
    php_darwin_die "could not canonicalize dependencies for $requested_formula"
  bash "$script_dir/select-cleanup-formulae.sh" "$cleanup_formulae" "$php_dependencies" \
    "$formulae_to_remove" || php_darwin_die 'could not select unrelated Homebrew formulae'
  # Keep older dependency kegs, but only pin versions that already satisfy
  # Homebrew. The source-cache planner installs/caches required newer versions.
  jq -r '.formulae[] | select(.outdated == false) | .name' "$work_dir/dependency-info.json" \
    > "$work_dir/current-dependencies.txt" || php_darwin_die 'could not select current dependencies'
  awk 'NR == FNR { if (NF) dependencies[$1]=1; next } NF && $1 in dependencies { print $1 }' \
    "$work_dir/current-dependencies.txt" "$cleanup_formulae" | LC_ALL=C sort -u > "$preserved_formulae_file"
  pipeline_status=("${PIPESTATUS[@]}")
  [ "${pipeline_status[0]}" -eq 0 ] && [ "${pipeline_status[1]}" -eq 0 ] || \
    php_darwin_die 'could not select installed PHP dependencies'
  while IFS= read -r installed_formula; do
    [ -n "$installed_formula" ] && installed_formulae+=("$installed_formula")
  done < "$formulae_to_remove"
  while IFS= read -r preserved_formula; do
    [ -n "$preserved_formula" ] && preserved_formulae+=("$preserved_formula")
  done < "$preserved_formulae_file"
  brew list --pinned | LC_ALL=C sort -u > "$pinned_formulae_file" || \
    php_darwin_die 'could not record pinned Homebrew formulae'
  while IFS= read -r preserved_formula; do
    [ -n "$preserved_formula" ] || continue
    grep -Fxq "$preserved_formula" "$pinned_formulae_file" || \
      preserved_formulae_to_pin+=("$preserved_formula")
  done < "$preserved_formulae_file"
  preserved_count=${#preserved_formulae[@]}
  removed_count=${#installed_formulae[@]}
  printf 'Preserving %s installed PHP dependencies; removing %s unrelated formulae\n' \
    "$preserved_count" "$removed_count"
  if [ "${#preserved_formulae_to_pin[@]}" -gt 0 ]; then
    printf '%s\n' "${preserved_formulae_to_pin[@]}" > "$added_pins_file" || \
      php_darwin_die 'could not record temporary Homebrew pins'
    brew pin --formula "${preserved_formulae_to_pin[@]}" || \
      php_darwin_die 'could not pin installed PHP dependencies during the cache build'
  else
    : > "$added_pins_file" || php_darwin_die 'could not record temporary Homebrew pins'
  fi
  if [ "${#installed_formulae[@]}" -gt 0 ]; then
    brew uninstall --force --ignore-dependencies "${installed_formulae[@]}" || \
      php_darwin_die 'could not remove unrelated preinstalled Homebrew formulae'
  fi
  # Keep current upstream bottles on persistent runners. Pruning the entire
  # download cache made each build fetch large dependencies again.
  brew cleanup || php_darwin_die 'Homebrew cleanup failed'

  brew list --formula --versions > "$preinstalled_formulae" || \
    php_darwin_die 'could not record the cleaned Homebrew formula baseline'
  LC_ALL=C sort -u "$preinstalled_formulae" -o "$preinstalled_formulae" || \
    php_darwin_die 'could not sort the cleaned Homebrew formula baseline'
  awk 'NR == FNR { if (NF) preserved[$1]=1; next } $1 in preserved' \
    "$preserved_formulae_file" "$preinstalled_formulae" > "$preserved_versions_file" || \
    php_darwin_die 'could not record cleaned PHP dependency versions'

  rm -rf "$brew_prefix/etc/php/$config_id" || \
    php_darwin_die 'could not clean the ephemeral runner PHP state'
  mkdir -p "$reuse_dir" || php_darwin_die 'could not create the shared runner baseline directory'
  bash "$script_dir/filesystem-manifest.sh" "$brew_prefix" "$before_manifest" "$snapshot_paths" || \
    php_darwin_die 'could not capture the initial Homebrew manifest'
  if [ ! -f "$reuse_baseline_manifest" ]; then
    cp "$before_manifest" "$reuse_baseline_manifest" || \
      php_darwin_die 'could not preserve the shared filesystem baseline'
  else
    cp "$reuse_baseline_manifest" "$before_manifest" || \
      php_darwin_die 'could not restore the shared filesystem baseline'
  fi
}

install_formula() {
  local current_formulae="$work_dir/current-formulae.txt"
  local current_preserved_versions="$work_dir/current-preserved-versions.txt"
  local dependency_changes="$work_dir/preserved-dependency-changes.txt"
  local php_bin="$brew_prefix/opt/$formula/bin/php"
  local php_config="$brew_prefix/opt/$formula/bin/php-config"
  local semver
  local semver_output

  [ -s "$before_manifest" ] || php_darwin_die 'the clean Homebrew snapshot is missing'
  if [ "$stage" != finalize ]; then
    brew install --verbose "$tap/$requested_formula" || php_darwin_die "could not install $requested_formula"
  fi
  brew unlink "$formula" >/dev/null 2>&1 || true
  brew link --overwrite --force "$formula" || php_darwin_die "could not link $formula after building"

  [ -f "$preserved_formulae_file" ] && [ -f "$preserved_versions_file" ] || \
    php_darwin_die 'the preserved PHP dependency snapshot is missing'
  brew list --formula --versions > "$current_formulae" || \
    php_darwin_die 'could not inspect PHP dependencies after formula installation'
  LC_ALL=C sort -u "$current_formulae" -o "$current_formulae" || \
    php_darwin_die 'could not sort PHP dependencies after formula installation'
  awk 'NR == FNR { if (NF) preserved[$1]=1; next } $1 in preserved' \
    "$preserved_formulae_file" "$current_formulae" > "$current_preserved_versions" || \
    php_darwin_die 'could not inspect preserved PHP dependency versions'
  if ! cmp -s "$preserved_versions_file" "$current_preserved_versions"; then
    LC_ALL=C comm -3 "$preserved_versions_file" "$current_preserved_versions" > "$dependency_changes" || \
      php_darwin_die 'could not compare preserved PHP dependency versions'
    php_darwin_die "brew install changed pinned PHP dependencies: $(tr '\n' ' ' < "$dependency_changes")"
  fi

  [ -x "$php_bin" ] || php_darwin_die "PHP binary missing after brew install: $php_bin"
  [ -x "$php_config" ] || php_darwin_die "php-config missing after brew install: $php_config"
  semver_output=$($php_config --version) || php_darwin_die 'php-config could not report the installed version'
  semver=${semver_output%%-*}
  php_darwin_validate_php_semver "$version" "$semver" || \
    php_darwin_die "installed PHP returned an invalid version: $semver_output"
  [ "${semver%.*}" = "$version" ] || php_darwin_die "installed PHP $semver for requested $version"
  printf '%s\n' "$semver" > "$work_dir/semver"
}

package_cache() {
  local asset
  local cached_extensions_json
  local extension
  local extension_parent
  local extension_path
  local extensions_source_hash
  local extension_tap
  local extension_tap_path
  local extension_type
  local formula_file
  local formula_sha256
  local installed_formula
  local keg_contents
  local keg_only
  local keg_member
  local keg_path
  local keg_relative
  local metadata_path
  local internal_metadata_path
  local internal_metadata_dir
  local link_formula
  local link_formulae=()
  local link_path
  local link_plan
  local link_relative
  local links_json
  local links_file
  local link_target
  local opt_link
  local opt_target
  local output
  local output_sha256
  local packages_json
  local package_info
  local package_info_tsv
  local package_formulae=()
  local runtime_dependency
  local runtime_dependency_formulae=()
  local pear_member
  local pear_members
  local pear_path
  local pecl_extension
  local pecl_extension_dir
  local php_src_commit
  local postinstall_path
  local postinstall_candidates_file
  local postinstall_paths_file
  local state_paths_json
  local state_paths_file
  local source_hash
  local tap_formulae
  local tar_paths
  local pipeline_status
  local compression_level
  local compression_long
  local semver
  local tap_commit
  local tap_branch
  local tap_member
  local tap_members
  local tap_path
  local tap_repository
  local tap_snapshot
  local tap_snapshot_path

  [ -s "$work_dir/semver" ] || php_darwin_die 'the installed PHP version is missing'
  IFS= read -r semver < "$work_dir/semver" || php_darwin_die 'could not read the installed PHP version'
  tap_path=$(brew --repository "$tap") || php_darwin_die "could not resolve the $tap repository"
  tap_commit=$(git -C "$tap_path" rev-parse HEAD) || php_darwin_die 'could not resolve the homebrew-php commit'
  [ "$tap_commit" = "$source_commit" ] || php_darwin_die 'homebrew-php moved away from the pinned source commit'
  tap_branch=$(php_darwin_package_config tap_branch) || exit 1
  tap_repository=$(php_darwin_package_config tap_repository) || exit 1
  tap_snapshot=$(php_darwin_package_config tap_snapshot) || exit 1
  case "$tap_snapshot" in var/php-darwin/*) ;; *)
    php_darwin_die "unsafe Homebrew tap snapshot path: $tap_snapshot"
    ;;
  esac
  case "$tap_snapshot" in *$'\n'*|*$'\r'*|*$'\t'*|*'/../'*|../*|*/..|*'//'* )
    php_darwin_die "unsafe Homebrew tap snapshot path: $tap_snapshot"
    ;;
  esac
  formula_file=$(brew formula "$tap/$requested_formula") || \
    php_darwin_die "could not resolve $tap/$requested_formula"
  [ -n "$tap_commit" ] && [ -f "$formula_file" ] || php_darwin_die "could not resolve formula state from $tap"
  formula_sha256=$(php_darwin_sha256 "$formula_file") || php_darwin_die 'could not hash the formula source'
  source_hash=$(HOMEBREW_PHP_PATH="$tap_path" bash "$script_dir/../lib/source-hash.sh" "$version") || \
    php_darwin_die 'could not hash the complete PHP formula set'
  [[ "$source_hash" =~ ^[0-9a-f]{64}$ ]] || php_darwin_die 'invalid PHP formula source hash'
  extension_tap=$(php_darwin_package_config extension_tap) || exit 1
  extension_tap_path=$(brew --repository "$extension_tap") || \
    php_darwin_die "could not resolve the $extension_tap repository"
  extensions_source_hash=$(HOMEBREW_EXTENSIONS_PATH="$extension_tap_path" \
    HOMEBREW_EXTENSIONS_REF="$extension_source_commit" \
    bash "$script_dir/extensions-source-hash.sh" "$version") || \
    php_darwin_die 'could not hash the cached extension sources'
  [[ "$extensions_source_hash" =~ ^[0-9a-f]{64}$ ]] || \
    php_darwin_die 'invalid cached extension source hash'
  php_src_commit=
  if [ "$(php_darwin_version_channel "$version")" = nightly ]; then
    php_src_commit=$(HOMEBREW_PHP_PATH="$tap_path" bash "$script_dir/php-src-commit.sh" "$version") || \
      php_darwin_die 'could not resolve the nightly PHP source commit'
  fi

  : > "$packages_file"
  : > "$archive_paths"
  [ -s "$cached_extensions_file" ] || php_darwin_die 'cached coverage extensions are missing'
  awk -F '\t' '
    NF != 3 || $1 !~ /^[A-Za-z0-9_]+$/ || $2 !~ /^(extension|zend_extension)$/ ||
      $3 !~ /^(Cellar|lib)\// || $3 ~ /(^|\/)\.\.($|\/)/ ||
      $3 !~ ("/" $1 "\\.so$") { exit 1 }
  ' "$cached_extensions_file" || php_darwin_die 'cached extension paths are invalid'
  if ! cmp -s <(bash "$script_dir/cached-extensions.sh" "$version" | LC_ALL=C sort -u) \
    <(awk -F '\t' '{ print $1 }' "$cached_extensions_file" | LC_ALL=C sort -u); then
    php_darwin_die "cached extensions are incomplete for PHP $version"
  fi
  while IFS=$'\t' read -r extension extension_type extension_path; do
    [ -f "$brew_prefix/$extension_path" ] && [ ! -L "$brew_prefix/$extension_path" ] || \
      php_darwin_die "cached extension is missing: $extension_path"
    extension_parent=${extension_path%/*}
    while [ "$extension_parent" != "${extension_parent%/*}" ]; do
      [ ! -L "$brew_prefix/$extension_parent" ] || \
        php_darwin_die "cached extension path traverses a symlink: $extension_path"
      extension_parent=${extension_parent%/*}
    done
    printf '%s\n' "$extension_path" >> "$archive_paths" || \
      php_darwin_die "could not archive cached $extension"
  done < "$cached_extensions_file"
  brew deps "$tap/$requested_formula" > "$raw_runtime_dependencies" || \
    php_darwin_die "could not resolve installed runtime dependencies for $requested_formula"
  LC_ALL=C sort -u "$raw_runtime_dependencies" -o "$raw_runtime_dependencies" || \
    php_darwin_die 'could not sort installed runtime dependencies'
  awk 'NF != 1 || $1 !~ /^([A-Za-z0-9@+._-]+\/){0,2}[A-Za-z0-9@+._-]+$/ { exit 1 }' \
    "$raw_runtime_dependencies" || \
    php_darwin_die "Homebrew returned an invalid runtime dependency for $requested_formula"
  while IFS= read -r runtime_dependency; do
    [ -n "$runtime_dependency" ] && runtime_dependency_formulae+=("$runtime_dependency")
  done < "$raw_runtime_dependencies"
  [ "${#runtime_dependency_formulae[@]}" -gt 0 ] || \
    php_darwin_die "Homebrew returned no runtime dependencies for $requested_formula"
  brew info --json=v2 --formula "${runtime_dependency_formulae[@]}" | \
    bash "$script_dir/canonicalize-formulae.sh" > "$runtime_dependencies"
  pipeline_status=("${PIPESTATUS[@]}")
  [ "${pipeline_status[0]}" -eq 0 ] && [ "${pipeline_status[1]}" -eq 0 ] || \
    php_darwin_die "could not canonicalize runtime dependencies for $requested_formula"
  brew list --formula --versions > "$installed_formulae_raw" || \
    php_darwin_die 'could not record installed Homebrew formula versions'
  awk 'NF' "$installed_formulae_raw" > "$installed_formulae_file" || \
    php_darwin_die 'could not filter installed Homebrew formula versions'
  LC_ALL=C sort -u "$installed_formulae_file" -o "$installed_formulae_file" || \
    php_darwin_die 'could not sort installed Homebrew formula versions'
  bash "$script_dir/select-packages.sh" "$runtime_dependencies" "$installed_formulae_file" \
    "$formula" "$packages_to_archive" || php_darwin_die 'could not select the cache runtime package set'
  while IFS= read -r installed_formula; do
    [ -n "$installed_formula" ] && package_formulae+=("$installed_formula")
  done < "$packages_to_archive"
  [ "${#package_formulae[@]}" -gt 0 ] || php_darwin_die 'cache runtime package set is empty'
  package_info="$work_dir/package-info.json"
  package_info_tsv="$work_dir/package-info.tsv"
  brew info --json=v2 "${package_formulae[@]}" > "$package_info" || \
    php_darwin_die 'could not inspect installed Homebrew package metadata'
  jq -e --rawfile selected "$packages_to_archive" '
    ($selected | split("\n") | map(select(length > 0)) | sort) as $selected |
    ([.formulae[].name] | sort) == $selected and
    all(.formulae[]; .keg_only | type == "boolean")
  ' "$package_info" >/dev/null || php_darwin_die 'Homebrew package metadata did not match the cache runtime package set'
  tap_formulae=$(jq -ce --arg tap "$tap" --arg formula "$formula" '
    ([.formulae[] | select(.tap == $tap or ((.full_name // "") | startswith($tap + "/"))) | .name] + [$formula]) |
    unique | sort |
    select(length > 0 and all(.[]; test("^[A-Za-z0-9@+._-]+$")))
  ' "$package_info") || php_darwin_die "could not identify cached formulae from $tap"
  jq -r '.formulae[] | [.name, .keg_only] | @tsv' "$package_info" > "$package_info_tsv" || \
    php_darwin_die 'could not serialize Homebrew package metadata'
  while IFS= read -r installed_formula; do
    opt_link="$brew_prefix/opt/$installed_formula"
    [ -L "$opt_link" ] || php_darwin_die "missing opt link for installed dependency: $installed_formula"
    opt_target=$(readlink "$opt_link")
    case "$opt_target" in
      "../Cellar/$installed_formula/"*) ;;
      *) php_darwin_die "unsafe opt target for $installed_formula: $opt_target" ;;
    esac
    keg_only=$(awk -F '\t' -v formula="$installed_formula" '$1 == formula { print $2; found=1; exit } END { exit !found }' \
      "$package_info_tsv") || php_darwin_die "missing Homebrew package metadata for $installed_formula"
    case "$keg_only" in true|false) ;; *) php_darwin_die "invalid keg-only state for $installed_formula" ;; esac
    printf '%s\t%s\t%s\n' "$installed_formula" "$opt_target" "$keg_only" >> "$packages_file"
    if [ "$keg_only" = false ] || [ "$installed_formula" = "$formula" ]; then
      link_formulae+=("$installed_formula")
    fi
    keg_relative=${opt_target#../}
    keg_path="$brew_prefix/$keg_relative"
    [ -d "$keg_path" ] || php_darwin_die "missing keg for installed dependency: $keg_path"
    keg_contents="$work_dir/keg-contents-${installed_formula//\//_}.bin"
    find "$keg_path" ! -type d -print0 > "$keg_contents" || \
      php_darwin_die "could not list $installed_formula"
    while IFS= read -r -d '' keg_member; do
      case "$keg_member" in
        "$brew_prefix"/*) printf '%s\n' "${keg_member#"$brew_prefix"/}" >> "$archive_paths" ;;
        *) php_darwin_die "Homebrew returned an out-of-prefix path for $installed_formula: $keg_member" ;;
      esac
    done < "$keg_contents"
    printf 'opt/%s\n' "$installed_formula" >> "$archive_paths"
  done < "$packages_to_archive"

  [ "${#link_formulae[@]}" -gt 0 ] || php_darwin_die 'cache has no linked Homebrew formulae'
  link_plan="$work_dir/homebrew-link-plan.txt"
  links_file="$work_dir/links.tsv"
  : > "$links_file"
  brew unlink --dry-run "${link_formulae[@]}" > "$link_plan" || \
    php_darwin_die 'could not inspect Homebrew package links'
  while IFS= read -r link_path; do
    case "$link_path" in "$brew_prefix"/*) ;; *) continue ;; esac
    [ -L "$link_path" ] || php_darwin_die "Homebrew link plan contained a non-symlink: $link_path"
    link_relative=${link_path#"$brew_prefix"/}
    case "${link_relative%%/*}" in
      Frameworks|bin|etc|include|lib|sbin|share) ;;
      *) php_darwin_die "Homebrew link plan contained an unsafe path: $link_relative" ;;
    esac
    link_target=$(readlink "$link_path") || php_darwin_die "could not read Homebrew link: $link_path"
    case "$link_relative$link_target" in *$'\n'*|*$'\r'*|*$'\t'*)
      php_darwin_die "unsupported Homebrew link: $link_relative"
      ;;
    esac
    printf '%s\t%s\n' "$link_relative" "$link_target" >> "$links_file"
    printf '%s\n' "$link_relative" >> "$archive_paths"
  done < "$link_plan"
  for link_formula in "${link_formulae[@]}"; do
    link_relative="var/homebrew/linked/$link_formula"
    link_path="$brew_prefix/$link_relative"
    [ -L "$link_path" ] || php_darwin_die "Homebrew linked-keg marker is missing: $link_formula"
    link_target=$(readlink "$link_path") || php_darwin_die "could not read the linked-keg marker for $link_formula"
    case "$link_target" in "../../../Cellar/$link_formula/"*) ;;
      *) php_darwin_die "unsafe linked-keg marker for $link_formula: $link_target" ;;
    esac
    printf '%s\t%s\n' "$link_relative" "$link_target" >> "$links_file"
    printf '%s\n' "$link_relative" >> "$archive_paths"
  done
  LC_ALL=C sort -u "$links_file" -o "$links_file" || php_darwin_die 'could not sort Homebrew links'
  awk -F '\t' 'seen[$1]++ { exit 1 }' "$links_file" || php_darwin_die 'Homebrew link plan contains duplicate paths'
  [ -s "$links_file" ] || php_darwin_die 'Homebrew link plan is empty'
  awk -F '\t' -v formula="$formula" \
    '$1 == "bin/php" && index($2, "../Cellar/" formula "/") == 1 && $2 ~ /\/bin\/php$/ { found=1 }
     END { exit !found }' "$links_file" || \
    php_darwin_die 'the cache does not contain the default PHP binary link'

  pear_path=$(php_darwin_pear_path "$version" "$formula") || exit 1
  [ -d "$brew_prefix/$pear_path" ] || php_darwin_die "formula post-install did not create $pear_path"
  pear_members="$work_dir/pear-paths.txt"
  find "$brew_prefix/$pear_path" ! -type d -print0 > "$pear_members" || \
    php_darwin_die 'could not inspect formula-managed PEAR state'
  while IFS= read -r -d '' pear_member; do
    case "$pear_member" in
      "$brew_prefix/$pear_path/"*) ;;
      *) php_darwin_die "unsafe formula-managed PEAR path: $pear_member" ;;
    esac
    case "$pear_member" in *$'\n'*|*$'\r'*) php_darwin_die "unsupported PEAR path: $pear_member" ;; esac
    printf '%s\n' "${pear_member#"$brew_prefix"/}" >> "$archive_paths"
  done < "$pear_members"
  pecl_extension_dir=$("$brew_prefix/opt/$formula/bin/php-config" --extension-dir) || \
    php_darwin_die 'could not determine the Homebrew PECL extension directory'
  pecl_extension=${pecl_extension_dir##*/}
  [[ "$pecl_extension" =~ ^[A-Za-z0-9._-]+$ ]] || \
    php_darwin_die "invalid Homebrew PECL extension directory: $pecl_extension"

  bash "$script_dir/filesystem-manifest.sh" "$brew_prefix" "$after_manifest" "$snapshot_paths" || \
    php_darwin_die 'could not capture the installed Homebrew manifest'
  LC_ALL=C comm -13 "$before_manifest" "$after_manifest" > "$changed_manifest" || \
    php_darwin_die 'could not compare Homebrew manifests'
  state_paths_file="$work_dir/state-paths.txt"
  awk -F '\t' '
    NR == FNR { extensions[$3]=1; next }
    $2 != "d" && $1 !~ /^var\/homebrew\/(linked|locks|pinned)(\/|$)/ && !($1 in extensions) { print $1 }
  ' "$cached_extensions_file" "$changed_manifest" > "$state_paths_file"
  pipeline_status=("${PIPESTATUS[@]}")
  [ "${pipeline_status[0]}" -eq 0 ] || \
    php_darwin_die 'could not create the archive path list'
  postinstall_paths_file="$work_dir/postinstall-paths.txt"
  postinstall_candidates_file="$work_dir/postinstall-candidates.txt"
  php_darwin_postinstall_paths "$version" "$formula" "$build" "$ts" > "$postinstall_candidates_file" || \
    php_darwin_die 'could not resolve formula-managed post-install paths'
  : > "$postinstall_paths_file" || php_darwin_die 'could not create the post-install path list'
  while IFS= read -r postinstall_path; do
    if [ -s "$brew_prefix/$postinstall_path" ]; then
      printf '%s\n' "$postinstall_path" >> "$postinstall_paths_file" || \
        php_darwin_die "could not record $postinstall_path"
    else
      case "$postinstall_path" in */pear.conf)
        php_darwin_die "formula post-install did not create $postinstall_path"
        ;;
      esac
    fi
  done < "$postinstall_candidates_file"
  cat "$postinstall_paths_file" >> "$state_paths_file" || \
    php_darwin_die 'could not add formula-managed post-install paths'
  LC_ALL=C sort -u "$state_paths_file" -o "$state_paths_file" || \
    php_darwin_die 'could not sort Homebrew state paths'
  cat "$state_paths_file" >> "$archive_paths" || php_darwin_die 'could not add Homebrew state paths'
  tap_snapshot_path="$brew_prefix/$tap_snapshot"
  if [ -e "$tap_snapshot_path" ] || [ -L "$tap_snapshot_path" ]; then
    [ -d "$tap_snapshot_path" ] && [ ! -L "$tap_snapshot_path" ] || \
      php_darwin_die "Homebrew tap snapshot path is not a directory: $tap_snapshot"
    find "$tap_snapshot_path" -mindepth 1 -delete || \
      php_darwin_die 'could not clean the Homebrew tap snapshot'
    rmdir "$tap_snapshot_path" || php_darwin_die 'could not remove the empty Homebrew tap snapshot'
  fi
  mkdir -p "${tap_snapshot_path%/*}" || php_darwin_die 'could not create the Homebrew tap snapshot parent'
  bash "$script_dir/create-tap-snapshot.sh" "$tap_path" "$tap_commit" "$tap_repository" \
    "$tap_branch" "$tap_snapshot_path" || php_darwin_die 'could not create the Homebrew tap snapshot'
  tap_members="$work_dir/tap-paths.bin"
  find "$tap_snapshot_path" ! -type d -print0 > "$tap_members" || \
    php_darwin_die 'could not inspect the Homebrew tap snapshot'
  while IFS= read -r -d '' tap_member; do
    case "$tap_member" in *$'\n'*|*$'\r'*) php_darwin_die "unsupported Homebrew tap path: $tap_member" ;; esac
    printf '%s\n' "${tap_member#"$brew_prefix"/}" >> "$archive_paths" || \
      php_darwin_die 'could not add the Homebrew tap snapshot to the archive'
  done < "$tap_members"
  LC_ALL=C sort -u "$archive_paths" -o "$archive_paths" || php_darwin_die 'could not sort the archive path list'
  [ -s "$archive_paths" ] || php_darwin_die 'filesystem snapshot did not capture any installed files'
  bash "$script_dir/filter-archive.sh" "$brew_prefix" "$archive_paths" "$work_dir/runtime-paths.txt" || \
    php_darwin_die 'could not filter cache documentation'
  mv "$work_dir/runtime-paths.txt" "$archive_paths" || php_darwin_die 'could not update the runtime archive paths'
  awk -F '\t' 'FILENAME == ARGV[1] { kept[$0]=1; next } $1 in kept' \
    "$archive_paths" "$links_file" > "$work_dir/runtime-links.tsv" || \
    php_darwin_die 'could not filter documentation links from the cache metadata'
  mv "$work_dir/runtime-links.tsv" "$links_file" || php_darwin_die 'could not update the cache link metadata'

  asset=$(php_darwin_asset "$version" "$build" "$ts" "$arch") || exit 1
  metadata_path="$work_dir/${asset%.tar.zst}.json"
  mkdir -p "${GITHUB_WORKSPACE:?}/builds" || php_darwin_die 'could not create the build output directory'

  packages_json="$work_dir/packages.json"
  jq -Rn '[inputs | split("\t") | {name:.[0],opt_target:.[1],keg_only:(.[2] == "true")}]' \
    < "$packages_file" > "$packages_json" || \
    php_darwin_die 'could not create the Homebrew package manifest'
  cached_extensions_json="$work_dir/cached-extensions.json"
  jq -Rn '[inputs | split("\t") | {name:.[0],type:.[1],path:.[2]}]' \
    < "$cached_extensions_file" > "$cached_extensions_json" || \
    php_darwin_die 'could not create the cached extension manifest'
  links_json="$work_dir/links.json"
  jq -Rn '[inputs | split("\t") | {path:.[0],target:.[1]}]' < "$links_file" > "$links_json" || \
    php_darwin_die 'could not create the Homebrew link manifest'
  state_paths_json="$work_dir/state-paths.json"
  jq -Rn '[inputs]' < "$state_paths_file" > "$state_paths_json" || \
    php_darwin_die 'could not create the Homebrew state manifest'
  jq --arg archive "$asset" \
    --arg architecture "$arch" \
    --arg brew_prefix "$brew_prefix" \
    --arg build "$build" \
    --arg created_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg formula "$formula" \
    --arg formula_sha256 "$formula_sha256" \
    --arg extensions_source_hash "$extensions_source_hash" \
    --arg homebrew_extensions_commit "$extension_source_commit" \
    --arg homebrew_php_commit "$tap_commit" \
    --slurpfile extensions "$cached_extensions_json" \
    --arg macos_version "$(sw_vers -productVersion)" \
    --slurpfile links "$links_json" \
    --argjson minimum_macos "$minimum_macos" \
    --slurpfile packages "$packages_json" \
    --arg pear_path "$pear_path" \
    --arg pecl_extension "$pecl_extension" \
    --arg php_semver "$semver" \
    --arg php_src_commit "$php_src_commit" \
    --arg php_version "$version" \
    --arg platform_key "$platform_key" \
    --arg requested_formula "$requested_formula" \
    --arg runner_image "${ImageVersion:-}" \
    --arg source_hash "$source_hash" \
    --slurpfile state_paths "$state_paths_json" \
    --argjson tap_formulae "$tap_formulae" \
    --arg tap_snapshot "$tap_snapshot" \
    --arg thread_safety "$ts" \
    '.archive=$archive | .architecture=$architecture | .brew_prefix=$brew_prefix | .build=$build |
     .created_at=$created_at | .extensions_source_hash=$extensions_source_hash |
     .formula=$formula | .formula_sha256=$formula_sha256 |
     .extensions=$extensions[0] | .homebrew_extensions_commit=$homebrew_extensions_commit |
     .homebrew_php_commit=$homebrew_php_commit | .links=$links[0] | .macos_version=$macos_version |
     .minimum_macos=$minimum_macos | .packages=$packages[0] | .pear_path=$pear_path |
     .pecl_extension=$pecl_extension | .php_semver=$php_semver |
     .php_src_commit=$php_src_commit | .php_version=$php_version | .platform_key=$platform_key |
     .requested_formula=$requested_formula |
     .runner_image=$runner_image | .source_hash=$source_hash | .state_paths=$state_paths[0] |
     .tap_formulae=$tap_formulae | .tap_snapshot=$tap_snapshot |
     .thread_safety=$thread_safety' \
    "$script_dir/../../templates/cache-metadata.json" > "$metadata_path" || \
    php_darwin_die 'could not create archive metadata'

  "${PHP_DARWIN_NODE:-node}" "$script_dir/package-inputs.cjs" capture "$metadata_path" || \
    php_darwin_die 'could not record package dependency inputs'
  internal_metadata_path=$(php_darwin_metadata_path "$asset") || exit 1
  internal_metadata_dir="$brew_prefix/${internal_metadata_path%/*}"
  [ ! -L "$internal_metadata_dir" ] || php_darwin_die 'embedded metadata directory is a symlink'
  [ ! -e "$internal_metadata_dir" ] || [ -d "$internal_metadata_dir" ] || \
    php_darwin_die 'embedded metadata path is not a directory'
  mkdir -p "$internal_metadata_dir" || \
    php_darwin_die 'could not create the embedded metadata directory'
  cp "$metadata_path" "$brew_prefix/$internal_metadata_path" || \
    php_darwin_die 'could not stage embedded archive metadata'
  tar_paths="$work_dir/tar-paths.txt"
  printf '%s\n' "$internal_metadata_path" > "$tar_paths" || php_darwin_die 'could not create archive inputs'
  cat "$archive_paths" >> "$tar_paths" || php_darwin_die 'could not add archive inputs'

  output="${GITHUB_WORKSPACE:?}/builds/$asset"
  compression_level=$(jq -er '.compression_level | select(type == "number" and floor == . and . >= 1 and . <= 22)' \
    "$script_dir/../../conf/build.json") || php_darwin_die 'archive compression level is not configured'
  compression_long=$(jq -er '.compression_long | select(type == "number" and floor == . and . > 0)' \
    "$script_dir/../../conf/build.json") || php_darwin_die 'archive compression window is not configured'
  tar --no-recursion -cf - -C "$brew_prefix" -T "$tar_paths" | \
    zstd --ultra -"$compression_level" --long="$compression_long" -T0 -q -o "$output"
  pipeline_status=("${PIPESTATUS[@]}")
  [ "${pipeline_status[0]}" -eq 0 ] && [ "${pipeline_status[1]}" -eq 0 ] || \
    php_darwin_die 'could not compress the archive'
  rm -f "$brew_prefix/$internal_metadata_path" || php_darwin_die 'could not remove staged archive metadata'
  find "$tap_snapshot_path" -mindepth 1 -delete || php_darwin_die 'could not clean the staged Homebrew tap snapshot'
  rmdir "$tap_snapshot_path" || php_darwin_die 'could not remove the staged Homebrew tap snapshot'
  cp "$metadata_path" "${GITHUB_WORKSPACE:?}/builds/${asset%.tar.zst}.json" || \
    php_darwin_die 'could not copy archive metadata'
  output_sha256=$(php_darwin_sha256 "$output") || php_darwin_die 'could not hash the archive'
  printf '%s  %s\n' "$output_sha256" "$asset" > "$output.sha256" || \
    php_darwin_die 'could not write the archive checksum'
}

verify_cache() {
  local actual_checksum
  local asset
  local checksum
  local contents
  local embedded_metadata
  local extension_tap
  local extension_tap_path
  local expected_extensions_source_hash
  local expected_php_src_commit
  local invalid_path
  local invalid_managed_path
  local managed_paths
  local metadata
  local max_archive_bytes
  local missing_managed_path
  local output
  local output_bytes
  local tap_snapshot
  local tap_path

  asset=$(php_darwin_asset "$version" "$build" "$ts" "$arch") || exit 1
  output="${GITHUB_WORKSPACE:?}/builds/$asset"
  metadata="${GITHUB_WORKSPACE:?}/builds/${asset%.tar.zst}.json"
  tap_snapshot=$(php_darwin_package_config tap_snapshot) || exit 1
  contents="$work_dir/archive-contents.txt"
  embedded_metadata="$work_dir/embedded-metadata.json"
  [ -f "$output" ] || php_darwin_die "archive not found: $output"
  [ -f "$metadata" ] || php_darwin_die "metadata not found: $metadata"
  expected_php_src_commit=
  if [ "$(php_darwin_version_channel "$version")" = nightly ]; then
    tap_path=$(brew --repository "$tap") || php_darwin_die "could not resolve the $tap repository"
    expected_php_src_commit=$(HOMEBREW_PHP_PATH="$tap_path" bash "$script_dir/php-src-commit.sh" "$version") || \
      php_darwin_die 'could not resolve the expected nightly PHP source commit'
  fi
  extension_tap=$(php_darwin_package_config extension_tap) || exit 1
  extension_tap_path=$(brew --repository "$extension_tap") || \
    php_darwin_die "could not resolve the $extension_tap repository"
  expected_extensions_source_hash=$(HOMEBREW_EXTENSIONS_PATH="$extension_tap_path" \
    HOMEBREW_EXTENSIONS_REF="$extension_source_commit" \
    bash "$script_dir/extensions-source-hash.sh" "$version") || \
    php_darwin_die 'could not resolve the expected cached extension source hash'
  macos_major=$(sw_vers -productVersion) || php_darwin_die 'could not determine the macOS version'
  macos_major=${macos_major%%.*}
  php_darwin_validate_cache_metadata "$metadata" "$version" "$build" "$ts" "$arch" \
    "$brew_prefix" "$macos_major" "$source_commit" "$expected_php_src_commit" '' '' '' '' \
    "$extension_source_commit" "$expected_extensions_source_hash" >/dev/null || \
    php_darwin_die 'archive metadata validation failed'
  if ! cmp -s <(bash "$script_dir/cached-extensions.sh" "$version" records | LC_ALL=C sort -u) \
    <(jq -r '.extensions[] | [.name,.type] | @tsv' "$metadata" | LC_ALL=C sort -u); then
    php_darwin_die 'archive metadata omitted a configured cached extension'
  fi
  zstd -t "$output" || php_darwin_die 'archive integrity check failed'
  bash "$script_dir/list-archive.sh" "$output" "$contents" || \
    php_darwin_die 'archive contents could not be listed'
  ! grep -Eq '(^/|(^|/)\.\.(/|$)|/$)' "$contents" || \
    php_darwin_die 'archive contains an absolute, parent-relative, or directory entry'
  invalid_path=$(awk '
    NR == FNR { if ($1 !~ /^#/ && NF) allowed[$1]=1; next }
    { split($0, path, "/"); if (!(path[1] in allowed)) { print; exit } }
  ' "$archive_roots" "$contents") || php_darwin_die 'could not validate archive path roots'
  [ -z "$invalid_path" ] || php_darwin_die "archive contains a disallowed path: $invalid_path"
  managed_paths="$work_dir/verify-managed-paths.txt"
  jq -r '.links[].path, .state_paths[], .extensions[].path, (.packages[].name | "opt/" + .)' "$metadata" \
    > "$managed_paths" || php_darwin_die 'could not create the managed archive path list'
  printf '%s\n' "$(php_darwin_metadata_path "$asset")" >> "$managed_paths" || \
    php_darwin_die 'could not add the managed metadata path'
  LC_ALL=C sort -u "$managed_paths" -o "$managed_paths" || \
    php_darwin_die 'could not sort managed archive paths'
  missing_managed_path=$(awk '
    NR == FNR { contents[$0]=1; next }
    !($0 in contents) { print; exit }
  ' "$contents" "$managed_paths") || php_darwin_die 'could not compare managed paths with archive contents'
  [ -z "$missing_managed_path" ] || \
    php_darwin_die "archive does not contain managed path: $missing_managed_path"
  invalid_managed_path=$(awk -v pear="$(jq -r '.pear_path' "$metadata")/" -v tap="$tap_snapshot/" '
    NR == FNR { exact[$0]=1; next }
    index($0, "Cellar/") == 1 || index($0, pear) == 1 || index($0, tap) == 1 || ($0 in exact) { next }
    { print; exit }
  ' "$managed_paths" "$contents") || php_darwin_die 'could not validate managed archive paths'
  [ -z "$invalid_managed_path" ] || \
    php_darwin_die "archive contains an unmanaged path: $invalid_managed_path"
  while IFS= read -r extension; do
    if grep -Eq "^etc/php/[^/]+/conf\\.d/[^/]*${extension}[^/]*\\.ini$" "$contents"; then
      php_darwin_die "archive enables cached $extension by default"
    fi
  done < <(bash "$script_dir/cached-extensions.sh" "$version")
  grep -q '^Cellar/' "$contents" || php_darwin_die 'archive does not contain Homebrew kegs'
  grep -Fxq "opt/$formula" "$contents" || php_darwin_die 'archive does not contain the PHP opt link'
  grep -Fxq "$(php_darwin_metadata_path "$asset")" "$contents" || \
    php_darwin_die 'archive does not contain embedded installation metadata'
  grep -Fxq "$tap_snapshot/.git/HEAD" "$contents" || \
    php_darwin_die 'archive does not contain the Homebrew tap Git metadata'
  grep -Fxq "$tap_snapshot/Formula/$formula.rb" "$contents" || \
    php_darwin_die 'archive does not contain the requested Homebrew tap formula'
  [ "$(head -n 1 "$contents")" = "$(php_darwin_metadata_path "$asset")" ] || \
    php_darwin_die 'embedded installation metadata is not the first archive member'
  awk -v prefix="$(jq -r '.pear_path' "$metadata")/" 'index($0, prefix) == 1 { found=1; exit } END { exit !found }' \
    "$contents" || \
    php_darwin_die 'archive does not contain formula-managed PEAR state'
  bash "$script_dir/../installer/read-metadata.sh" "$output" "$(php_darwin_metadata_path "$asset")" \
    "$embedded_metadata" || php_darwin_die 'embedded installation metadata could not be read'
  cmp -s "$metadata" "$embedded_metadata" || \
    php_darwin_die 'embedded installation metadata does not match its external record'
  grep -Fxq "var/homebrew/linked/$formula" "$contents" || \
    php_darwin_die 'archive does not contain the requested PHP linked-keg marker'
  checksum=$(php_darwin_checksum_from_file "$output.sha256" "$asset") || \
    php_darwin_die 'archive checksum record is missing'
  actual_checksum=$(php_darwin_sha256 "$output") || php_darwin_die 'could not hash the archive during verification'
  [ "$checksum" = "$actual_checksum" ] || php_darwin_die 'archive checksum validation failed'
  max_archive_bytes=$(jq -er --arg version "$version" '
    .max_archive_bytes[$version] |
    select(type == "number" and floor == . and . > 0)
  ' "$script_dir/../../conf/build.json") || \
    php_darwin_die "archive size limit is not configured for PHP $version"
  output_bytes=$(wc -c < "$output")
  output_bytes=${output_bytes//[[:space:]]/}
  [ "$output_bytes" -le "$max_archive_bytes" ] || \
    php_darwin_die "archive is $output_bytes bytes; expected at most $max_archive_bytes"
  ls -lh "${GITHUB_WORKSPACE:?}/builds"
}

reset_homebrew() {
  local added_pin
  local added_pins=()
  local postinstall_path
  local reset_asset
  local extension
  local extension_path
  local extension_type

  brew services stop "$formula" >/dev/null 2>&1 || true
  if [ -f "$cached_extensions_file" ]; then
    while IFS=$'\t' read -r extension extension_type extension_path; do
      [[ "$extension" =~ ^[A-Za-z0-9_]+$ ]] && \
        [[ "$extension_type" =~ ^(extension|zend_extension)$ ]] && \
        [[ "$extension_path" =~ ^(Cellar|lib)/ ]] && \
        [ "${extension_path##*/}" = "$extension.so" ] || \
        php_darwin_die 'cached extension reset path is invalid'
      if [ -w "$brew_prefix/${extension_path%/*}" ]; then
        rm -f "$brew_prefix/$extension_path" || php_darwin_die "could not reset cached $extension"
      else
        command -v sudo >/dev/null 2>&1 || \
          php_darwin_die 'sudo is required to reset a protected cached extension'
        sudo -n rm -f "$brew_prefix/$extension_path" || \
          php_darwin_die "could not reset cached $extension in a protected directory"
      fi
    done < "$cached_extensions_file"
  fi
  if brew list --versions "$formula" >/dev/null 2>&1; then
    brew uninstall --force --ignore-dependencies "$formula" || \
      php_darwin_die "could not reset $formula after packaging"
  fi
  rm -rf "${brew_prefix:?}/${pear_path:?}" || php_darwin_die "could not reset $pear_path"
  while IFS= read -r postinstall_path; do
    [ -n "$postinstall_path" ] || continue
    rm -rf "${brew_prefix:?}/${postinstall_path:?}" || \
      php_darwin_die "could not reset $postinstall_path"
  done < <(php_darwin_postinstall_paths "$version" "$formula" "$build" "$ts")
  rm -rf "${brew_prefix:?}/etc/php/${config_id:?}" || \
    php_darwin_die "could not reset etc/php/$config_id"
  ! brew list --versions "$formula" >/dev/null 2>&1 || \
    php_darwin_die "$formula remained installed after the runner reset"
  if [ -f "$added_pins_file" ]; then
    while IFS= read -r added_pin; do
      [ -n "$added_pin" ] && added_pins+=("$added_pin")
    done < "$added_pins_file"
  fi
  if [ "${#added_pins[@]}" -gt 0 ]; then
    brew unpin --formula "${added_pins[@]}" || \
      php_darwin_die 'could not remove temporary Homebrew dependency pins'
  fi
  reset_asset=$(php_darwin_asset "$version" "$build" "$ts" "$arch") || exit 1
  printf 'Reset Homebrew after packaging %s\n' "$reset_asset"
}

case "$stage" in
  prepare) prepare_homebrew ;;
  cleanup) clean_homebrew ;;
  install|finalize) install_formula ;;
  package) package_cache ;;
  verify) verify_cache ;;
  reset) reset_homebrew ;;
  all)
    prepare_homebrew
    clean_homebrew
    install_formula
    bash "$script_dir/build-extensions.sh"
    package_cache
    verify_cache
    ;;
  *) php_darwin_die 'usage: build.sh prepare|cleanup|install|finalize|package|verify|reset|all' ;;
esac
