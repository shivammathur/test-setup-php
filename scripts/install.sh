#!/usr/bin/env bash

# This file is generated from the named source files below. It is deliberately
# plain shell code so the standalone installer can be audited before execution.

# Source: scripts/lib/lib.sh

unset php_darwin_configured_versions_data php_darwin_configured_variants_data


php_darwin_die() {
  if [ -n "${PHP_DARWIN_PHASE:-}" ]; then
    printf 'php-darwin: %s failed: %s\n' "$PHP_DARWIN_PHASE" "$*" >&2
  else
    printf 'php-darwin: %s\n' "$*" >&2
  fi
  exit 1
}

php_darwin_configure_homebrew_environment() {
  export HOMEBREW_NO_AUTO_UPDATE=1
  export HOMEBREW_NO_AUTOREMOVE=1
  export HOMEBREW_NO_ENV_HINTS=1
  export HOMEBREW_NO_INSTALL_CLEANUP=1
  export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
  export HOMEBREW_NO_INSTALL_FROM_API=1
}

php_darwin_tap_repository_path() {
  local tap=$1 repository name

  # The no-argument command exits early in brew.sh. Asking for a tap runs
  # Homebrew's full shell initialization just to append this fixed path.
  if [[ "$tap" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]]; then
    repository=$(brew --repository) || return 1
    if [[ "$repository" = /* ]] && [ -d "$repository/Library/Homebrew" ]; then
      name=${tap#*/}
      case "$name" in homebrew-*) name=${name#homebrew-} ;; linuxbrew-*) name=${name#linuxbrew-} ;; esac
      printf '%s/Library/Taps/%s/homebrew-%s\n' "$repository" "${tap%%/*}" "$name"
      return 0
    fi
  fi
  brew --repository "$tap"
}

php_darwin_select_ruby() {
  local repository candidate

  # macOS system Ruby can spend several seconds loading its standard library
  # for the first time. Homebrew already ships an independent Ruby runtime.
  # Probe only the installed binary; never download or start `brew ruby` here.
  export PHP_DARWIN_RUBY=/usr/bin/ruby
  repository=$(brew --repository 2>/dev/null) || return 0
  candidate="$repository/Library/Homebrew/vendor/portable-ruby/current/bin/ruby"
  if [[ "$repository" = /* ]] && [ -x "$candidate" ] && \
    "$candidate" --disable=gems -rjson -rfileutils -rfind -rtempfile -e 'exit 0' >/dev/null 2>&1; then
    PHP_DARWIN_RUBY=$candidate
  fi
  return 0
}

php_darwin_ruby() {
  local binary=${PHP_DARWIN_RUBY:-/usr/bin/ruby}
  [ -x "$binary" ] || return 78
  "$binary" --disable=gems "$@"
}

php_darwin_is_git_worktree() {
  local tap_path=$1

  [ -d "$tap_path" ] && [ ! -L "$tap_path" ] || return 1
  [ -e "$tap_path/.git" ]
}

php_darwin_trust_entry() {
  local collection=$1
  local target=$2
  local trust_json=${3:-}
  local trust_state

  case "$collection" in taps|formulae) ;; *) return 2 ;; esac
  [ -n "$trust_json" ] || trust_json=$(brew trust --json=v1) || return 2
  trust_state=$(jq -er --arg collection "$collection" --arg target "$target" '
    if (.[$collection] | type) != "array" then
      error("invalid Homebrew trust response")
    elif (.[$collection] | index($target)) != null then
      "true"
    else
      "false"
    end
  ' <<< "$trust_json") || return 2
  [ "$trust_state" = true ]
}

php_darwin_tap_trusted() {
  php_darwin_trust_entry taps "$1" "${2:-}"
}

php_darwin_formula_trusted() {
  php_darwin_trust_entry formulae "$1" "${2:-}"
}

php_darwin_prepare_tap_path() {
  local tap_path=$1
  local backup_path=$2

  if [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
    printf 'Homebrew tap backup path already exists: %s\n' "$backup_path" >&2
    return 1
  fi
  if [ ! -e "$tap_path" ] && [ ! -L "$tap_path" ]; then
    printf 'absent\n'
    return 0
  fi
  if [ -L "$tap_path" ]; then
    printf 'Homebrew tap path is a symlink: %s\n' "$tap_path" >&2
    return 1
  fi
  if [ ! -d "$tap_path" ]; then
    printf 'Homebrew tap path is not a directory: %s\n' "$tap_path" >&2
    return 1
  fi
  if php_darwin_is_git_worktree "$tap_path"; then
    printf 'git\n'
    return 0
  fi
  if ! mv "$tap_path" "$backup_path" 2>/dev/null; then
    command -v sudo >/dev/null 2>&1 || return 1
    sudo -n mv "$tap_path" "$backup_path" || return 1
  fi
  printf 'backed-up\n'
}

php_darwin_restore_tap_path() {
  local tap_path=$1
  local backup_path=$2

  [ -d "$backup_path" ] && [ ! -L "$backup_path" ] || {
    printf 'Homebrew tap backup is not a directory: %s\n' "$backup_path" >&2
    return 1
  }
  if [ -e "$tap_path" ] || [ -L "$tap_path" ]; then
    printf 'Homebrew tap path exists during restore: %s\n' "$tap_path" >&2
    return 1
  fi
  mkdir -p "${tap_path%/*}" || return 1
  if ! mv "$backup_path" "$tap_path" 2>/dev/null; then
    command -v sudo >/dev/null 2>&1 || return 1
    sudo -n mv "$backup_path" "$tap_path"
  fi
}

php_darwin_tap_backup_path() {
  local brew_prefix=$1
  local tap_path=$2
  local tmp_dir=$3
  local backup_root="$brew_prefix/var/php-darwin"
  local tmp_name=${tmp_dir##*/}
  local tmp_suffix

  case "$tap_path" in
    "$brew_prefix/Library/Taps/"*|"$brew_prefix/Homebrew/Library/Taps/"*) ;;
    *)
      printf 'Invalid Homebrew tap path: %s\n' "$tap_path" >&2
      return 1
      ;;
  esac
  [ -d "$backup_root" ] && [ ! -L "$backup_root" ] || {
    printf 'Invalid php-darwin backup directory: %s\n' "$backup_root" >&2
    return 1
  }
  case "$tmp_name" in
    php-darwin-install.*) tmp_suffix=${tmp_name#php-darwin-install.} ;;
    *)
      printf 'Invalid php-darwin installation directory: %s\n' "$tmp_dir" >&2
      return 1
      ;;
  esac
  case "$tmp_suffix" in ''|*[!A-Za-z0-9]*)
    printf 'Invalid php-darwin installation directory: %s\n' "$tmp_dir" >&2
    return 1
    ;;
  esac
  printf '%s/tap-backup.%s\n' "$backup_root" "$tmp_name"
}

php_darwin_remove_tap_backup() {
  local brew_prefix=$1
  local backup_path=$2
  local backup_prefix="$brew_prefix/var/php-darwin/tap-backup.php-darwin-install."
  local backup_suffix

  case "$backup_path" in
    "$backup_prefix"*) backup_suffix=${backup_path#"$backup_prefix"} ;;
    *)
      printf 'Unsafe Homebrew tap backup path: %s\n' "$backup_path" >&2
      return 1
      ;;
  esac
  case "$backup_suffix" in ''|*[!A-Za-z0-9]*)
    printf 'Unsafe Homebrew tap backup path: %s\n' "$backup_path" >&2
    return 1
    ;;
  esac
  [ -d "$backup_path" ] && [ ! -L "$backup_path" ] || {
    printf 'Homebrew tap backup is not a directory: %s\n' "$backup_path" >&2
    return 1
  }
  if find "$backup_path" -mindepth 1 -delete >/dev/null 2>&1 && \
    rmdir "$backup_path" >/dev/null 2>&1; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n find "$backup_path" -mindepth 1 -delete && sudo -n rmdir "$backup_path"
}

php_darwin_remove_tap_path() {
  local brew_prefix=$1
  local tap_path=$2

  case "$tap_path" in
    "$brew_prefix/Library/Taps/"*|"$brew_prefix/Homebrew/Library/Taps/"*) ;;
    *)
      printf 'Unsafe Homebrew tap path: %s\n' "$tap_path" >&2
      return 1
      ;;
  esac
  [ -d "$tap_path" ] && [ ! -L "$tap_path" ] || {
    printf 'Homebrew tap path is not a directory: %s\n' "$tap_path" >&2
    return 1
  }
  if find "$tap_path" -mindepth 1 -delete >/dev/null 2>&1 && \
    rmdir "$tap_path" >/dev/null 2>&1; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n find "$tap_path" -mindepth 1 -delete && sudo -n rmdir "$tap_path"
}

php_darwin_load_versions() {
  local channel
  local configured=
  local extra
  local seen=
  local version

  [ "${php_darwin_configured_versions_data+x}" != x ] || return 0
  while read -r channel version extra; do
    [ -n "$channel" ] || continue
    case "$channel" in \#*) continue ;; stable|nightly) ;; *) return 1 ;; esac
    [ -n "$version" ] && [ -z "$extra" ] && [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    case " $seen " in *" $version "*) return 1 ;; esac
    seen="$seen $version"
    configured=${configured:+"$configured"$'\n'}"$channel $version"
  done < <(php_darwin_read_config versions)
  [ -n "$configured" ] || return 1
  php_darwin_configured_versions_data=$configured
}

php_darwin_configured_versions() {
  php_darwin_load_versions || {
    printf 'Invalid PHP version configuration\n' >&2
    return 1
  }
  printf '%s\n' "$php_darwin_configured_versions_data"
}

php_darwin_load_variants() {
  local build
  local configured=
  local extra
  local seen=
  local ts

  [ "${php_darwin_configured_variants_data+x}" != x ] || return 0
  while read -r build ts extra; do
    [ -n "$build" ] || continue
    case "$build" in \#*) continue ;; release|debug) ;; *) return 1 ;; esac
    case "$ts" in nts|zts) ;; *) return 1 ;; esac
    [ -z "$extra" ] || return 1
    case " $seen " in *" $build/$ts "*) return 1 ;; esac
    seen="$seen $build/$ts"
    configured=${configured:+"$configured"$'\n'}"$build $ts"
  done < <(php_darwin_read_config variants)
  [ -n "$configured" ] || return 1
  php_darwin_configured_variants_data=$configured
}

php_darwin_configured_variants() {
  php_darwin_load_variants || {
    printf 'Invalid PHP build variant configuration\n' >&2
    return 1
  }
  printf '%s\n' "$php_darwin_configured_variants_data"
}

php_darwin_validate_version() {
  local requested_version=${1:-}
  local configured_channel
  local configured_version
  local extra

  php_darwin_load_versions || php_darwin_die 'invalid PHP version configuration'
  while read -r configured_channel configured_version extra; do
    if [ "$configured_version" = "$requested_version" ]; then
      return 0
    fi
  done <<< "$php_darwin_configured_versions_data"
  php_darwin_die "unsupported PHP version: ${requested_version:-<empty>}"
}

php_darwin_is_php_formula() {
  [[ "${1:-}" =~ ^php(@[0-9]+\.[0-9]+)?(-debug)?(-zts)?$ ]]
}

php_darwin_keg_formula_reference() {
  local brew_prefix=$1
  local formula=$2
  local keg_relative=$3
  local custom_tap=${4:-}
  local receipt
  local source_tap

  [[ "$formula" =~ ^[A-Za-z0-9@+._-]+$ ]] || return 1
  case "$keg_relative" in "Cellar/$formula/"*) ;; *) return 1 ;; esac
  receipt="$brew_prefix/$keg_relative/INSTALL_RECEIPT.json"
  source_tap=$(jq -er '.source.tap // empty | select(type == "string")' "$receipt" 2>/dev/null) || \
    source_tap=
  if [ -n "$source_tap" ]; then
    [[ "$source_tap" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  fi
  if [ -n "$custom_tap" ] && [ "$source_tap" = "$custom_tap" ]; then
    printf '%s/%s\n' "$source_tap" "$formula"
  else
    printf '%s\n' "$formula"
  fi
}

php_darwin_version_channel() {
  local requested_version=${1:-}
  local configured_channel
  local configured_version
  local extra

  php_darwin_load_versions || php_darwin_die 'invalid PHP version configuration'
  while read -r configured_channel configured_version extra; do
    if [ "$configured_version" = "$requested_version" ]; then
      printf '%s\n' "$configured_channel"
      return 0
    fi
  done <<< "$php_darwin_configured_versions_data"
  php_darwin_die "unsupported PHP version: ${requested_version:-<empty>}"
}

php_darwin_validate_channel() {
  local version=${1:-}
  local expected=${2:-}
  local actual

  case "$expected" in stable|nightly) ;; *) php_darwin_die "unsupported release channel: ${expected:-<empty>}" ;; esac
  actual=$(php_darwin_version_channel "$version") || return 1
  [ "$actual" = "$expected" ] || php_darwin_die "PHP $version is $actual, not $expected"
}

php_darwin_validate_build() {
  case "${1:-}" in
    release|debug) ;;
    *) php_darwin_die "build must be release or debug: ${1:-<empty>}" ;;
  esac
}

php_darwin_validate_ts() {
  case "${1:-}" in
    nts|zts) ;;
    *) php_darwin_die "thread safety must be nts or zts: ${1:-<empty>}" ;;
  esac
}

php_darwin_normalize_arch() {
  case "${1:-$(uname -m)}" in
    arm64|aarch64) printf 'arm64\n' ;;
    x86_64|amd64) printf 'x86_64\n' ;;
    *) php_darwin_die "unsupported architecture: ${1:-<empty>}" ;;
  esac
}

php_darwin_expected_prefix() {
  local arch

  arch=$(php_darwin_normalize_arch "${1:-}") || return 1
  php_darwin_platform_value "$arch" brew_prefix
}

php_darwin_platform_value() {
  local arch=$1
  local key=$2

  case "$key" in brew_prefix|build_runner|minimum_macos|platform_key|test_runners) ;; *) return 1 ;; esac
  jq -er --arg arch "$arch" --arg key "$key" '.[$arch][$key]' \
    < <(php_darwin_read_config platforms.json)
}

php_darwin_platform_arches() {
  jq -er 'keys[]' < <(php_darwin_read_config platforms.json)
}

php_darwin_legacy_platforms() {
  local legacy_config

  legacy_config=$(php_darwin_read_config legacy-platforms.json) || return 1
  jq -cer '.platforms | select(type == "object")' <<< "$legacy_config"
}

php_darwin_package_config() {
  jq -er --arg key "$1" '.[$key]' < <(php_darwin_read_config package.json) || \
    php_darwin_die "package configuration is missing: $1"
}

php_darwin_current_version() {
  php_darwin_package_config current_version
}

php_darwin_nightly_versions() {
  local channel
  local configured_version
  local extra
  local nightly_versions=

  php_darwin_load_versions || php_darwin_die 'invalid PHP version configuration'
  while read -r channel configured_version extra; do
    [ "$channel" = nightly ] || continue
    nightly_versions=${nightly_versions:+"$nightly_versions"$'\n'}"$configured_version"
  done <<< "$php_darwin_configured_versions_data"
  [ -n "$nightly_versions" ] || php_darwin_die 'no nightly PHP version is configured'
  printf '%s\n' "$nightly_versions"
}

php_darwin_expected_asset_count() {
  local build
  local platform_count
  local ts
  local variant_count

  php_darwin_load_variants || php_darwin_die 'could not load configured variants'
  variant_count=0
  while read -r build ts; do
    variant_count=$((variant_count + 1))
  done <<< "$php_darwin_configured_variants_data"
  platform_count=$(jq -er 'keys | length | select(. > 0)' \
    < <(php_darwin_read_config platforms.json)) || php_darwin_die 'could not count configured platforms'
  printf '%s\n' "$((variant_count * platform_count))"
}

php_darwin_formula_suffix() {
  local build=${1:-release}
  local ts=${2:-nts}
  local suffix=

  php_darwin_validate_build "$build"
  php_darwin_validate_ts "$ts"
  [ "$build" = debug ] && suffix=-debug
  [ "$ts" = zts ] && suffix="$suffix-zts"
  printf '%s\n' "$suffix"
}

php_darwin_validate_php_semver() {
  local semver=$2
  local version=$1

  [[ "$semver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(alpha[0-9]+|beta[0-9]+|RC[0-9]+)?$ ]] || return 1
  case "$semver" in "$version".*) ;; *) return 1 ;; esac
}

php_darwin_formula() {
  local version=$1
  local current_version=${4:-}
  local suffix

  php_darwin_validate_version "$version"
  suffix=$(php_darwin_formula_suffix "${2:-release}" "${3:-nts}") || return 1
  [ -n "$current_version" ] || current_version=$(php_darwin_package_config current_version) || return 1
  if [ "$version" = "$current_version" ]; then
    printf 'php%s\n' "$suffix"
  else
    printf 'php@%s%s\n' "$version" "$suffix"
  fi
}

php_darwin_requested_formula() {
  local version=$1
  local suffix

  php_darwin_validate_version "$version"
  suffix=$(php_darwin_formula_suffix "${2:-release}" "${3:-nts}") || return 1
  printf 'php@%s%s\n' "$version" "$suffix"
}

php_darwin_pear_path() {
  local version=$1
  local formula=$2
  local formula_version

  php_darwin_validate_version "$version"
  case "$formula" in
    php@*)
      formula_version=${formula#php@}
      case "$formula_version" in
        "$version"|"$version-debug"|"$version-zts"|"$version-debug-zts") ;;
        *) php_darwin_die "invalid versioned PHP formula for PEAR state: $formula" ;;
      esac
      printf 'share/pear@%s\n' "$formula_version"
      ;;
    php|php-debug|php-zts|php-debug-zts) printf 'share/pear\n' ;;
    *) php_darwin_die "invalid PHP formula for PEAR state: $formula" ;;
  esac
}

php_darwin_config_id() {
  local version=$1
  local suffix

  php_darwin_validate_version "$version"
  suffix=$(php_darwin_formula_suffix "${2:-release}" "${3:-nts}") || return 1
  printf '%s%s\n' "$version" "$suffix"
}

php_darwin_metadata_path() {
  local asset=$1
  local asset_arch

  [[ "$asset" =~ ^php_[0-9]+\.[0-9]+-(nts|zts)-(debug|release)\+darwin_(arm64|x86_64)\.tar\.zst$ ]] || \
    php_darwin_die "invalid cache archive name: $asset"
  asset_arch=${asset##*+darwin_}
  asset_arch=${asset_arch%.tar.zst}
  php_darwin_normalize_arch "$asset_arch" >/dev/null || return 1
  printf 'var/php-darwin/%s.json\n' "${asset%.tar.zst}"
}

php_darwin_postinstall_paths() {
  local version=$1
  local formula=$2
  local config_id
  local scope
  local configured_path
  local extra

  php_darwin_validate_version "$version"
  config_id=$(php_darwin_config_id "$version" "${3:-release}" "${4:-nts}") || return 1
  while read -r scope configured_path extra; do
    [ -n "$scope" ] || continue
    case "$scope" in \#*) continue ;; esac
    [ -z "$extra" ] || php_darwin_die "invalid post-install path: $scope $configured_path $extra"
    case "$scope" in
      all) ;;
      versioned) [[ "$formula" = php@* ]] || continue ;;
      *) php_darwin_die "invalid post-install path scope: $scope" ;;
    esac
    configured_path=${configured_path//\{config\}/$config_id}
    case "$configured_path" in
      "etc/php/$config_id/"*) printf '%s\n' "$configured_path" ;;
      *) php_darwin_die "unsafe post-install path: $configured_path" ;;
    esac
  done < <(php_darwin_read_config postinstall-paths)
}

php_darwin_asset() {
  local version=$1
  local version_major
  local version_minor
  local build=${2:-release}
  local ts=${3:-nts}
  local arch

  IFS=. read -r version_major version_minor _ <<< "$version"
  php_darwin_validate_version "$version_major.$version_minor"
  php_darwin_validate_build "$build"
  php_darwin_validate_ts "$ts"
  arch=$(php_darwin_normalize_arch "${4:-}") || return 1
  printf 'php_%s-%s-%s+darwin_%s.tar.zst\n' "$version" "$ts" "$build" "$arch"
}

php_darwin_download_asset() {
  local asset=$1
  local asset_arch
  local sha256=$2

  [[ "$asset" =~ ^php_[0-9]+\.[0-9]+-(nts|zts)-(debug|release)\+darwin_(arm64|x86_64)\.tar\.zst$ ]] || return 1
  asset_arch=${asset##*+darwin_}
  asset_arch=${asset_arch%.tar.zst}
  php_darwin_normalize_arch "$asset_arch" >/dev/null 2>&1 || return 1
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s.%s.tar.zst\n' "${asset%.tar.zst}" "$sha256"
}

php_darwin_sha256() {
  local hash_output

  if [ -x /usr/bin/openssl ]; then
    hash_output=$(/usr/bin/openssl dgst -sha256 "$1") || return 1
    hash_output=${hash_output##* }
  elif command -v sha256sum >/dev/null 2>&1; then
    hash_output=$(sha256sum "$1") || return 1
  else
    hash_output=$(shasum -a 256 "$1") || return 1
  fi
  printf '%s\n' "${hash_output%% *}"
}

php_darwin_checksum_from_file() {
  local checksum_file=$1
  local asset=$2

  [ -f "$checksum_file" ] || {
    printf 'Checksum file not found: %s\n' "$checksum_file" >&2
    return 1
  }
  awk -v name="$asset" '
    !NF { next }
    NF != 2 || $1 !~ /^[0-9a-f]+$/ || length($1) != 64 { invalid=1; next }
    $2 == name { matches++; hash=$1 }
    END {
      if (invalid || matches != 1) exit 1
      print hash
    }
  ' "$checksum_file"
}

php_darwin_release_manifest_url() {
  local release_repository=$1
  local version=$2

  [[ "$release_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  php_darwin_validate_version "$version"
  printf 'https://github.com/%s/releases/download/php-%s/php-%s-manifest.json?cache=%s\n' \
    "$release_repository" "$version" "$version" "$(date +%s)"
}

php_darwin_fetch_release_manifest() {
  local destination=$3
  local manifest_url
  local request_status=000
  local mirror_url
  local urls=()

  if [ -n "${4:-}" ]; then
    manifest_url=$4
  else
    manifest_url=$(php_darwin_release_manifest_url "$1" "$2") || return 1
  fi
  urls+=("$manifest_url")
  if [ -z "${4:-}" ] || [ -n "${PHP_DARWIN_MIRROR_URL:-}" ]; then
    mirror_url=$(php_darwin_release_mirror "$1" "$2") || return 1
    [ -z "$mirror_url" ] || urls+=("$mirror_url/php-$2-manifest.json")
    if [ -n "$mirror_url" ] && [ "${PHP_DARWIN_PREFER_MIRROR:-false}" = true ]; then
      urls=("$mirror_url/php-$2-manifest.json" "$manifest_url")
    fi
  fi
  for manifest_url in "${urls[@]}"; do
    if ! request_status=$(php_darwin_request_release "$manifest_url" "$destination"); then
      request_status=000
      continue
    fi
    if [ "$request_status" = 200 ]; then
      if php_darwin_validate_release_manifest "$destination" "$2" >/dev/null 2>&1; then
        printf '200\n'
        return 0
      fi
      printf 'php-darwin: invalid release manifest from %s\n' "$manifest_url" >&2
      request_status=000
    fi
  done
  printf '%s\n' "$request_status"
}

# Forks and explicit test URLs never silently fall back to production assets.
php_darwin_release_mirror() {
  local mirror=${PHP_DARWIN_MIRROR_URL-}
  if [ "${PHP_DARWIN_MIRROR_URL+x}" != x ] && [ "$1" = shivammathur/php-darwin ]; then
    mirror=https://artifacts.php-darwin.setup-php.com
  fi
  [ -n "$mirror" ] || return 0
  printf '%s/php-%s\n' "${mirror%/}" "$2"
}

php_darwin_request_release() {
  local status
  local result=0
  local range=()
  local attempt=1 attempts=3 connect_timeout=10 delay retry_after
  local headers=(--dump-header "$2.headers")
  [ -z "${6:-}" ] || range=(--range "$6-")

  # Retry every failed transfer on either origin, with a fixed attempt limit.
  # Each retry replaces its output at the same requested range offset;
  # the archive caller verifies the complete assembled SHA before extraction.
  while :; do
    result=0
    if [ "$attempts" -gt 1 ]; then : > "$2.headers" || return 1; fi
    status=$(curl --config <(php_darwin_read_config download.conf) \
      --retry 0 --connect-timeout "$connect_timeout" --speed-time "${4:-10}" --speed-limit "${3:-1024}" \
      --max-time "${5:-30}" ${range[@]+"${range[@]}"} ${headers[@]+"${headers[@]}"} \
      -fsSL -w '%{http_code}' "$1" -o "$2") || result=$?
    if [ "$result" -ne 0 ] || { [ "$status" != 200 ] && [ "$status" != 206 ]; }; then
      printf 'php-darwin: download failed (curl %s, HTTP %s): %s\n' \
        "$result" "${status:-000}" "$1" >&2
    fi
    [ "$attempt" -lt "$attempts" ] || break
    if [ "$result" -eq 0 ] && { [ "$status" = 200 ] || [ "$status" = 206 ]; }; then break; fi
    delay=$((1 << (attempt - 1)))
    retry_after=$(awk 'tolower($1) == "retry-after:" {gsub(/\r/, "", $2); value=$2} END {print value}' "$2.headers" 2>/dev/null) || retry_after=
    if [[ "$retry_after" =~ ^[0-9]{1,6}$ ]]; then
      retry_after=$((10#$retry_after))
      [ "$retry_after" -le 30 ] || retry_after=30
      [ "$retry_after" -le "$delay" ] || delay=$retry_after
    fi
    printf 'php-darwin: retrying transfer %s/%s in %ss\n' "$((attempt + 1))" "$attempts" "$delay" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
  [ "$attempts" -eq 1 ] || rm -f "$2.headers"
  # HTTP errors are classified by the caller (especially retired 404 assets).
  # --fail stops at their headers instead of downloading a slow error body.
  if [ "$result" -eq 22 ] && [[ "$status" =~ ^[45][0-9][0-9]$ ]]; then
    result=0
  fi
  printf '%s\n' "${status:-000}"
  return "$result"
}

php_darwin_release_manifest_has_current_platforms() {
  local expected_count
  local manifest=$1
  local platforms

  expected_count=$(php_darwin_expected_asset_count) || return 1
  platforms=$(php_darwin_read_config platforms.json) || return 1
  jq -e --argjson count "$expected_count" --argjson platforms "$platforms" '
    (.assets | type == "array") and (.assets | length == $count) and
    ([.assets[].architecture] | unique) == ($platforms | keys)
  ' "$manifest" >/dev/null
}

php_darwin_validate_release_manifest() {
  local manifest=$1
  local version=$2
  local channel=${3:-}
  local asset=${4:-}
  local expected_count
  local legacy_platforms
  local manifest_result
  local platforms

  [ -n "$channel" ] || channel=$(php_darwin_version_channel "$version") || return 1
  case "$channel" in stable|nightly) ;; *) return 1 ;; esac
  [ "$(php_darwin_version_channel "$version")" = "$channel" ] || return 1
  expected_count=$(php_darwin_expected_asset_count) || return 1
  platforms=$(php_darwin_read_config platforms.json) || return 1
  legacy_platforms=$(php_darwin_legacy_platforms) || return 1
  manifest_result=$(jq -er --arg channel "$channel" --arg version "$version" \
    --arg asset "$asset" --argjson count "$expected_count" --argjson platforms "$platforms" \
    --argjson legacy_platforms "$legacy_platforms" '
    ($platforms | keys) as $current_architectures |
    ($legacy_platforms | keys) as $legacy_architectures |
    ($count / ($platforms | length) * ($legacy_platforms | length)) as $legacy_count |
    (.assets // []) as $assets |
    ([$assets[].architecture] | unique) as $architectures |
    (if (($assets | length) == $count and $architectures == $current_architectures) then
       $platforms
     elif (($assets | length) == $legacy_count and $architectures == $legacy_architectures) then
       $legacy_platforms
     else
       null
     end) as $manifest_platforms |
    select(.schema == 1 and .php_version == $version and
    (.homebrew_php_commit | type == "string" and test("^[0-9a-f]{40}$")) and
    (((.homebrew_extensions_commit // "") == "") or
      (.homebrew_extensions_commit | type == "string" and test("^[0-9a-f]{40}$"))) and
    (((.extensions_source_hash // "") == "") or
      (.extensions_source_hash | type == "string" and test("^[0-9a-f]{64}$"))) and
    (.source_hash | type == "string" and test("^[0-9a-f]{64}$")) and
    (.php_semver | type == "string" and startswith($version + ".") and
      test("^[0-9]+\\.[0-9]+\\.[0-9]+(alpha[0-9]+|beta[0-9]+|RC[0-9]+)?$")) and
    (has("php_src_commit") and if $channel == "nightly" then
       (.php_src_commit | type == "string" and test("^[0-9a-f]{40}$"))
     else
       (.php_src_commit == "" or .php_src_commit == null)
     end) and
    (.assets | type == "array") and ($manifest_platforms != null) and
    ([.assets[].name] | unique | length) == (.assets | length) and
    ([.assets[] | (.download // .name)] | unique | length) == (.assets | length) and
    all(.assets[];
      . as $item | .architecture as $architecture |
      ($manifest_platforms[$architecture] != null) and
      (.build == "debug" or .build == "release") and
      (.thread_safety == "nts" or .thread_safety == "zts") and
      .name == ("php_" + $version + "-" + .thread_safety + "-" + .build +
        "+darwin_" + .architecture + ".tar.zst") and
      (.bytes | type == "number" and floor == . and . > 0) and
      (.minimum_macos | type == "number" and floor == . and . > 0 and
        . == $manifest_platforms[$architecture].minimum_macos) and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      ((.download // .name) as $download |
        ($download | type == "string") and
        ($download == $item.name or
          $download == ($item.name | sub("\\.tar\\.zst$"; "." + $item.sha256 + ".tar.zst")))))) |
    if $asset == "" then
      "valid"
    else
      [.assets[] | select(.name == $asset)] as $matching |
      select($matching | length == 1) |
      [$matching[0].sha256, .homebrew_php_commit,
       (if (.php_src_commit // "") == "" then "-" else .php_src_commit end),
       .php_semver, .source_hash, ($matching[0].download // $matching[0].name),
       (if (.homebrew_extensions_commit // "") == "" then "-" else .homebrew_extensions_commit end)] |
       @tsv
    end
  ' "$manifest") || return 1
  if [ -n "$asset" ]; then
    printf '%s\n' "$manifest_result"
  else
    [ "$manifest_result" = valid ]
  fi
}

php_darwin_validate_cache_metadata() {
  local metadata_file=$1
  local version=$2
  local build=$3
  local ts=$4
  local arch=$5
  local brew_prefix=$6
  local macos_major=$7
  local expected_commit=${8:-}
  local expected_php_src_commit=${9:-}
  local configured_current_version=${10:-}
  local configured_tap_snapshot=${11:-}
  local configured_minimum_macos=${12:-}
  local configured_platform_key=${13:-}
  local expected_extensions_commit=${14:-}
  local expected_extensions_source_hash=${15:-}
  local asset
  local channel
  local config_id
  local formula
  local minimum_macos
  local pear_path
  local platform_key
  local requested_formula
  local tap_snapshot

  channel=$(php_darwin_version_channel "$version") || return 1
  config_id=$(php_darwin_config_id "$version" "$build" "$ts") || return 1
  asset=$(php_darwin_asset "$version" "$build" "$ts" "$arch") || return 1
  formula=$(php_darwin_formula "$version" "$build" "$ts" "$configured_current_version") || return 1
  requested_formula=$(php_darwin_requested_formula "$version" "$build" "$ts") || return 1
  pear_path=$(php_darwin_pear_path "$version" "$formula") || return 1
  if [ -n "$configured_tap_snapshot" ]; then
    tap_snapshot=$configured_tap_snapshot
  else
    tap_snapshot=$(php_darwin_package_config tap_snapshot) || return 1
  fi
  if [ -n "$configured_minimum_macos" ] && [ -n "$configured_platform_key" ]; then
    minimum_macos=$configured_minimum_macos
    platform_key=$configured_platform_key
  else
    minimum_macos=$(php_darwin_platform_value "$arch" minimum_macos) || return 1
    platform_key=$(php_darwin_platform_value "$arch" platform_key) || return 1
  fi

  jq -er --arg version "$version" --arg channel "$channel" --arg build "$build" --arg ts "$ts" \
    --arg arch "$arch" --arg brew_prefix "$brew_prefix" --arg asset "$asset" --arg formula "$formula" \
    --arg expected_commit "$expected_commit" --arg expected_extensions_commit "$expected_extensions_commit" \
    --arg expected_extensions_source_hash "$expected_extensions_source_hash" \
    --arg expected_php_src_commit "$expected_php_src_commit" \
    --arg pear_path "$pear_path" --arg pear_conf "etc/php/$config_id/pear.conf" \
    --arg platform_key "$platform_key" --arg requested_formula "$requested_formula" \
    --arg tap_snapshot "$tap_snapshot" --argjson macos_major "$macos_major" \
    --argjson minimum_macos "$minimum_macos" '
    . as $metadata |
    select(.schema == 1 and .php_version == $version and .build == $build and
    .thread_safety == $ts and .architecture == $arch and .brew_prefix == $brew_prefix and
    .archive == $asset and .formula == $formula and .requested_formula == $requested_formula and
    .minimum_macos == $minimum_macos and .minimum_macos <= $macos_major and
    .platform_key == $platform_key and .pear_path == $pear_path and .tap_snapshot == $tap_snapshot and
    (.pecl_extension | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.homebrew_php_commit | type == "string" and test("^[0-9a-f]{40}$")) and
    ($expected_commit == "" or .homebrew_php_commit == $expected_commit) and
    ((.homebrew_extensions_commit // "") as $extensions_commit |
      (($extensions_commit == "" and $expected_extensions_commit == "") or
       ($extensions_commit | type == "string" and test("^[0-9a-f]{40}$") and
        ($expected_extensions_commit == "" or $extensions_commit == $expected_extensions_commit)))) and
    ((.extensions_source_hash // "") as $extensions_hash |
      (($extensions_hash == "" and $expected_extensions_source_hash == "") or
       ($extensions_hash | type == "string" and test("^[0-9a-f]{64}$") and
        ($expected_extensions_source_hash == "" or $extensions_hash == $expected_extensions_source_hash)))) and
    (.formula_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.source_hash | type == "string" and test("^[0-9a-f]{64}$")) and
    (has("php_src_commit") and if $channel == "nightly" then
       (.php_src_commit | type == "string" and test("^[0-9a-f]{40}$")) and
       ($expected_php_src_commit == "" or .php_src_commit == $expected_php_src_commit)
     else
       (.php_src_commit == "" or .php_src_commit == null)
     end) and
    (.php_semver | type == "string" and startswith($version + ".") and
      test("^[0-9]+\\.[0-9]+\\.[0-9]+(alpha[0-9]+|beta[0-9]+|RC[0-9]+)?$")) and
    (.links | type == "array" and length > 0) and
    ([.links[].path] | unique | length) == (.links | length) and
    all(.links[];
      (.path | type == "string" and
        test("^(Frameworks|bin|etc|include|lib|sbin|share|var/homebrew/linked)/") and
        (test("(^|/)\\.\\.(/|$)") | not) and test("^[^\\r\\n\\t]+$")) and
      (.target | type == "string" and test("^[^\\r\\n\\t]+$"))) and
    ((.extensions // []) | type == "array") and
    ([((.extensions // [])[].name)] | unique | length) == ((.extensions // []) | length) and
    ([((.extensions // [])[].path)] | unique | length) == ((.extensions // []) | length) and
    all((.extensions // [])[];
      . as $extension |
      ($extension.name | type == "string" and test("^[A-Za-z0-9_]+$")) and
      ($extension.type == "extension" or $extension.type == "zend_extension") and
      ($extension.path | type == "string" and test("^(Cellar|lib)/") and
        (test("(^|/)\\.\\.(/|$)") | not) and test("^[^\\\\\\r\\n\\t]+$") and
        endswith("/" + $extension.name + ".so"))) and
    (.state_paths | type == "array" and length > 0) and
    ([.state_paths[]] | unique | length) == (.state_paths | length) and
    any(.state_paths[]; . == $pear_conf) and
    all(.state_paths[];
      type == "string" and test("^(etc|var)/") and
      (test("^var/homebrew/(linked|locks|pinned)(/|$)") | not) and
      (test("(^|/)\\.\\.(/|$)") | not) and test("^[^\\r\\n\\t]+$")) and
    (.packages | type == "array" and length > 0) and
    ([.packages[].name] | unique | length) == (.packages | length) and
    any(.packages[]; .name == $formula) and
    all(.packages[];
      (.name | type == "string" and test("^[A-Za-z0-9@+._-]+$")) and
      (.keg_only | type == "boolean") and
      (.name as $name | .opt_target | split("/") |
        length == 4 and .[0] == ".." and .[1] == "Cellar" and .[2] == $name and
        (.[3] | type == "string" and test("^[^\\r\\n\\t/]+$") and . != "." and . != ".."))) and
    any(.links[]; .path == "bin/php" and
      (.target as $target | any($metadata.packages[];
        .name == $formula and $target == (.opt_target + "/bin/php")))) and
    ((.tap_formulae // []) as $tap_formulae |
      ($tap_formulae | type == "array") and
      ([$tap_formulae[]] | unique | length) == ($tap_formulae | length) and
      (($tap_formulae | length) == 0 or ($tap_formulae | index($formula)) != null) and
      all($tap_formulae[];
        type == "string" and test("^[A-Za-z0-9@+._-]+$") and
        (. as $tap_formula | any($metadata.packages[]; .name == $tap_formula))))) |
    [.homebrew_php_commit, .source_hash,
     (.packages[] | select(.name == $formula) | .opt_target | ltrimstr("../")),
     .pecl_extension, .php_semver] | @tsv
  ' "$metadata_file"
}

php_darwin_job_running() {
  kill -0 "$1" >/dev/null 2>&1
}

php_darwin_collect_job_pids() {
  local job_pid=$1

  ps -axo pid=,ppid= | awk -v root="$job_pid" '
    { parent[$1]=$2; pid[++count]=$1 }
    END {
      for (item_index=1; item_index<=count; item_index++) {
        current=pid[item_index]
        for (depth=0; depth<count && current in parent; depth++) {
          if (parent[current] == root) { print pid[item_index]; break }
          current=parent[current]
        }
      }
    }
  '
}

php_darwin_wait_for_job_pids() {
  local attempt=0
  local attempts=$1
  local job_pid
  local running

  shift

  while [ "$attempt" -lt "$attempts" ]; do
    running=false
    for job_pid in "$@"; do
      php_darwin_job_running "$job_pid" && running=true
    done
    [ "$running" = true ] || return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

php_darwin_signal_job_pids() {
  local job_pid
  local signal=$1

  shift
  for job_pid in "$@"; do
    php_darwin_job_running "$job_pid" || continue
    kill "-$signal" "$job_pid" >/dev/null 2>&1 || true
  done
}

php_darwin_reap_job() {
  local discovered_pid
  local grace_attempts=$2
  local job_pid=$1
  local tracked_pids=()

  [ -n "$job_pid" ] || return 0
  while IFS= read -r discovered_pid; do
    [ -n "$discovered_pid" ] && tracked_pids+=("$discovered_pid")
  done < <(php_darwin_collect_job_pids "$job_pid")
  if [ "$grace_attempts" -gt 0 ] && \
    php_darwin_wait_for_job_pids "$grace_attempts" "$job_pid" "${tracked_pids[@]}"; then
    wait "$job_pid" >/dev/null 2>&1 || true
    return 0
  fi
  while IFS= read -r discovered_pid; do
    [ -n "$discovered_pid" ] || continue
    case " ${tracked_pids[*]} " in *" $discovered_pid "*) ;; *) tracked_pids+=("$discovered_pid") ;; esac
  done < <(php_darwin_collect_job_pids "$job_pid")
  php_darwin_signal_job_pids TERM "$job_pid" "${tracked_pids[@]}"
  if ! php_darwin_wait_for_job_pids 10 "$job_pid" "${tracked_pids[@]}"; then
    php_darwin_signal_job_pids KILL "${tracked_pids[@]}" "$job_pid"
    php_darwin_wait_for_job_pids 10 "$job_pid" "${tracked_pids[@]}" || true
  fi
  wait "$job_pid" >/dev/null 2>&1 || true
}

php_darwin_read_config() {
  case "${1:-}" in
    archive-paths)
      cat <<'PHP_DARWIN_CONFIG_ARCHIVE_PATHS'
# Homebrew prefix roots permitted in an archive and merged during installation.
Cellar
Frameworks
bin
etc
include
lib
opt
sbin
share
var
PHP_DARWIN_CONFIG_ARCHIVE_PATHS
      ;;
    download.conf)
      cat <<'PHP_DARWIN_CONFIG_DOWNLOAD_CONF'
connect-timeout = 5
max-time = 30
retry = 2
retry-all-errors
retry-delay = 1
retry-max-time = 60
PHP_DARWIN_CONFIG_DOWNLOAD_CONF
      ;;
    package.json)
      cat <<'PHP_DARWIN_CONFIG_PACKAGE_JSON'
{
  "current_version": "8.5",
  "extension_tap": "shivammathur/extensions",
  "extension_tap_branch": "main",
  "extension_tap_repository": "https://github.com/shivammathur/homebrew-extensions",
  "release_repository": "shivammathur/php-darwin",
  "tap": "shivammathur/php",
  "tap_branch": "main",
  "tap_repository": "https://github.com/shivammathur/homebrew-php",
  "tap_snapshot": "var/php-darwin/homebrew-php"
}
PHP_DARWIN_CONFIG_PACKAGE_JSON
      ;;
    platforms.json)
      cat <<'PHP_DARWIN_CONFIG_PLATFORMS_JSON'
{
  "arm64": {
    "build_runner": "macos-14",
    "brew_prefix": "/opt/homebrew",
    "minimum_macos": 14,
    "platform_key": "arm64_sonoma",
    "test_runners": ["macos-14", "macos-15", "macos-26", "macos-latest"]
  },
  "x86_64": {
    "build_runner": "macos-15-intel",
    "brew_prefix": "/usr/local",
    "minimum_macos": 15,
    "platform_key": "sequoia",
    "test_runners": ["macos-15-intel", "macos-26-intel"]
  }
}
PHP_DARWIN_CONFIG_PLATFORMS_JSON
      ;;
    legacy-platforms.json)
      cat <<'PHP_DARWIN_CONFIG_LEGACY_PLATFORMS_JSON'
{
  "schema": 1,
  "purpose": "Validate ARM64-only release manifests",
  "platforms": {
    "arm64": {
      "minimum_macos": 14
    }
  }
}
PHP_DARWIN_CONFIG_LEGACY_PLATFORMS_JSON
      ;;
    postinstall-paths)
      cat <<'PHP_DARWIN_CONFIG_POSTINSTALL_PATHS'
# Formula-managed configuration recreated by Homebrew post_install.
all etc/php/{config}/pear.conf
versioned etc/php/{config}/conf.d/ext-intl.ini
versioned etc/php/{config}/conf.d/ext-opcache.ini
PHP_DARWIN_CONFIG_POSTINSTALL_PATHS
      ;;
    variants)
      cat <<'PHP_DARWIN_CONFIG_VARIANTS'
# build thread-safety
release nts
release zts
debug nts
debug zts
PHP_DARWIN_CONFIG_VARIANTS
      ;;
    versions)
      cat <<'PHP_DARWIN_CONFIG_VERSIONS'
# channel version
stable 5.6
stable 7.0
stable 7.1
stable 7.2
stable 7.3
stable 7.4
stable 8.0
stable 8.1
stable 8.2
stable 8.3
stable 8.4
stable 8.5
nightly 8.6
nightly 8.7
PHP_DARWIN_CONFIG_VERSIONS
      ;;
    release-manifest.json)
      cat <<'PHP_DARWIN_RELEASE_MANIFEST'
{}
PHP_DARWIN_RELEASE_MANIFEST
      ;;
    *) printf 'php-darwin: unknown embedded configuration: %s\n' "$1" >&2; return 1 ;;
  esac
}


# Source: scripts/installer/install-extensions.cjs
php_darwin_extension_installer() {
  cat <<'PHP_DARWIN_EXTENSION_INSTALLER'
#!/usr/bin/env node
// Standalone optional extension installer. No Homebrew operations or PHP installation.
const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { pipeline } = require('node:stream/promises');
const { Readable } = require('node:stream');

const packs = { imagick: ['imagick'], mongodb: ['mongodb'], memcached: ['igbinary', 'msgpack', 'memcached'] };
const origins = ['https://github.com/shivammathur/php-darwin/releases/download/extensions',
  'https://artifacts.php-darwin.setup-php.com/extensions'];
const hex = /^[a-f0-9]{64}$/;
function command(program, args, options = {}) {
  const result = spawnSync(program, args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...options });
  if (result.error || result.status !== 0) throw result.error || new Error(`${program} ${args.join(' ')} failed (${result.status}): ${result.stderr || result.stdout}`);
  return result.stdout.trim();
}
function digest(data) { return crypto.createHash('sha256').update(data).digest('hex'); }
function safePath(value) {
  return typeof value === 'string' && value.length > 0 && !/[\x00-\x1f\x7f\\]/.test(value) &&
    !value.startsWith('/') && value.split('/').every(part => part && part !== '.' && part !== '..');
}
function validateContext(context) {
  if (!context || !/^(?:5\.6|7\.[0-4]|8\.[0-7])$/.test(context.php_version) ||
      !['arm64', 'x86_64'].includes(context.architecture) ||
      !['release', 'debug'].includes(context.build) || !['nts', 'zts'].includes(context.thread_safety)) {
    throw new Error('Unsupported extension cache configuration');
  }
  return context;
}
function key(entry) {
  validateContext(entry);
  if (!Object.hasOwn(packs, entry.name)) throw new Error('Unknown extension pack');
  return [entry.name, entry.php_version, entry.build, entry.thread_safety, entry.architecture].join('-');
}
function validateEntry(entry) {
  key(entry);
  if (entry.schema !== 1 || !hex.test(entry.sha256) || !hex.test(entry.inputs_sha256) ||
      !/^[0-9]{8}$/.test(entry.php_api) ||
      !Number.isInteger(entry.bytes) || entry.bytes < 1 || entry.bytes > 180000000 ||
      !Number.isInteger(entry.minimum_macos) || entry.minimum_macos < 14 ||
      entry.file !== `${key(entry)}-${entry.sha256}.tar.zst`) throw new Error('Invalid extension cache metadata');
  return entry;
}
async function download(name, destination, { sha256, bytes, bases = origins,
  fresh = false, sleep = ms => new Promise(resolve => setTimeout(resolve, ms)) } = {}) {
  if (!safePath(name) || name.includes('/')) throw new Error('Invalid download name');
  let lastError;
  const missing = new Set();
  for (const base of bases) {
    const attempts = 3;
    for (let attempt = 1; attempt <= attempts; attempt++) {
      const temporary = `${destination}.partial`;
      try {
        missing.delete(base);
        // Give archives time to finish on either origin; metadata stays bounded.
        const response = await fetch(`${base}/${name}${fresh ? `?refresh=${Date.now()}` : ''}`, { signal: AbortSignal.timeout(bytes ? 300000 : 30000) });
        if (!response.ok || !response.body) {
          await response.body?.cancel();
          const retryAfter = response.headers.get('retry-after');
          if ([404, 410].includes(response.status)) missing.add(base);
          throw Object.assign(new Error(`HTTP ${response.status}`), {
            retryAfter: /^\d{1,6}$/.test(retryAfter || '') ? Math.min(30, Number(retryAfter)) : 0
          });
        }
        let received = 0;
        const hash = crypto.createHash('sha256');
        const limit = bytes || 2000000;
        await pipeline(Readable.fromWeb(response.body), async function* (source) {
          for await (const chunk of source) {
            received += chunk.length;
            if (received > limit) throw new Error('Download exceeds expected size');
            hash.update(chunk);
            yield chunk;
          }
        }, fs.createWriteStream(temporary, { flags: 'wx', mode: 0o600 }));
        if ((bytes && received !== bytes) || (sha256 && hash.digest('hex') !== sha256)) {
          throw new Error('Extension archive checksum/size mismatch');
        }
        await fsp.rename(temporary, destination);
        return;
      } catch (error) {
        lastError = error;
        await fsp.rm(temporary, { force: true });
        if (attempt === attempts) break;
        const delay = Math.max(attempt, error.retryAfter || 0);
        console.warn(`Extension download retry ${attempt + 1}/${attempts} in ${delay}s: ${error.message}`);
        await sleep(delay * 1000);
      }
    }
  }
  throw Object.assign(new Error(`Could not download ${name}: ${lastError.message}`), { retired: missing.size === bases.length });
}
async function prefetch(directory, context, requested, options = {}) {
  const started = performance.now();
  validateContext(context);
  const names = [...new Set(requested)];
  if (!names.length || names.some(name => !Object.hasOwn(packs, name))) throw new Error('Invalid requested extensions');
  await fsp.mkdir(directory, { recursive: true, mode: 0o700 });
  const manifestPath = path.join(directory, 'manifest.json');
  await download(`extensions-${context.php_version}-manifest.json`, manifestPath, options);
  const manifest = JSON.parse(await fsp.readFile(manifestPath, 'utf8'));
  if (manifest.schema !== 1 || !Array.isArray(manifest.assets)) throw new Error('Invalid extension manifest');
  let refreshed;
  const select = (manifest, name) => {
    if (manifest.schema !== 1 || !Array.isArray(manifest.assets)) throw new Error('Invalid extension manifest');
    const candidates = manifest.assets.filter(entry => entry.name === name &&
      Object.entries(context).every(([field, value]) => entry[field] === value));
    if (candidates.length !== 1) throw new Error(`No unique compatible archive for ${name}`);
    return validateEntry(candidates[0]);
  };
  const results = await Promise.allSettled(names.map(async name => {
    let entry = select(manifest, name);
    console.log(`Downloading ${name} cache (${entry.bytes} bytes)`);
    try {
      await download(entry.file, path.join(directory, entry.file), { ...options, sha256: entry.sha256, bytes: entry.bytes });
    } catch (error) {
      if (!error.retired) throw error;
      // Publication can retire the archive after this install read its manifest.
      // Refresh once, shared across packs; retain exact context and checksums.
      refreshed ||= (async () => {
        await download(`extensions-${context.php_version}-manifest.json`, manifestPath, { ...options, fresh: true });
        return JSON.parse(await fsp.readFile(manifestPath, 'utf8'));
      })();
      const replacement = select(await refreshed, name);
      if (replacement.file === entry.file) throw error;
      entry = replacement;
      await download(entry.file, path.join(directory, entry.file), { ...options, sha256: entry.sha256, bytes: entry.bytes });
    }
    await fsp.writeFile(path.join(directory, `${name}.json`), JSON.stringify(entry));
    try {
      // Use independent processes so extraction cannot block other downloads.
      // This overlaps PHP setup without loading or changing the active PHP.
      await (options.prepare || prepareDownloaded)(directory, name);
    } catch (error) {
      await fsp.rm(path.join(directory, `${name}.json`), { force: true });
      throw error;
    }
    return name;
  }));
  results.forEach((result, index) => {
    if (result.status === 'rejected') console.warn(`Extension cache ${names[index]}: ${result.reason.message}`);
  });
  console.log(`Extension cache preparation completed in ${((performance.now() - started) / 1000).toFixed(3)} seconds`);
  return results.filter(result => result.status === 'fulfilled').map(result => result.value);
}
// Keep the action's raw input opaque until it reaches the installer. Only
// unversioned pack requests are eligible; explicit disable/version/source
// requests for a pack or one of its serializers retain the caller's behavior.
function selectRequested(input) {
  const tokens = String(input).split(',').map(value => value.trim().toLowerCase().replace(/^(:)?php[-_]/, '$1'));
  return Object.entries(packs).filter(([name, modules]) => tokens.includes(name) &&
    !modules.some(module => tokens.some(token => token === `:${module}` ||
      token.startsWith(`${module}-`) || token.startsWith(`${module}@`))))
    .map(([name]) => name);
}
function requestedPacks(directory) {
  const names = fs.readFileSync(path.join(directory, 'requested.txt'), 'utf8').trim().split('\n').filter(Boolean);
  if (names.some(name => !Object.hasOwn(packs, name)) || new Set(names).size !== names.length) {
    throw new Error('Invalid requested extension packs');
  }
  return names;
}
function validateBase(entry, base) {
  validateContext(base);
  if (!['php_version', 'architecture', 'build', 'thread_safety'].every(field => entry[field] === base[field]) ||
      !entry.php_semver || !base.php_semver || entry.php_semver.replace(/-dev$/, '') !== base.php_semver.replace(/-dev$/, '') ||
      (entry.php_src_commit || '') !== (base.php_src_commit || '')) {
    throw new Error('Extension cache does not match the installed PHP release/source');
  }
}
function installDownloaded(directory, name) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [__filename, 'install', directory, name], { stdio: 'inherit' });
    child.once('error', reject);
    child.once('exit', code => code === 0 ? resolve() : reject(new Error(`Installing ${name} failed (${code})`)));
  });
}
function enableInstalled(directory, name, scanDirectory, { php = 'php', environmentFile = process.env.GITHUB_ENV } = {}) {
  const entry = readEntry(directory, name);
  const prefix = entry.architecture === 'arm64' ? '/opt/homebrew' : '/usr/local';
  const destination = path.join(prefix, 'var/php-darwin/extensions', entry.sha256);
  if (fs.realpathSync(destination) !== destination) throw new Error('Unsafe installed extension directory');
  const installedMetadata = JSON.parse(fs.readFileSync(path.join(destination, 'metadata.json'), 'utf8'));
  if (key(installedMetadata) !== key(entry) || installedMetadata.inputs_sha256 !== entry.inputs_sha256) {
    throw new Error('Installed extension metadata changed');
  }
  const environment = packEnvironment(installedMetadata, destination);
  const env = { ...process.env, ...environment };
  const loaded = JSON.parse(command(php, ['-r', 'echo json_encode(get_loaded_extensions());'], { env })).map(value => value.toLowerCase());
  const missing = packs[name].filter(module => !loaded.includes(module));
  fs.mkdirSync(scanDirectory, { recursive: true });
  if (fs.realpathSync(scanDirectory) !== scanDirectory) throw new Error('PHP configuration directory traverses a symlink');
  const ini = path.join(scanDirectory, `zz-php-darwin-${name}.ini`);
  const marker = '; Managed by php-darwin optional extension installer\n';
  let previous;
  let iniStat;
  try { iniStat = fs.lstatSync(ini); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (iniStat) {
    if (!iniStat.isFile()) throw new Error('Unsafe optional extension configuration');
    previous = fs.readFileSync(ini, 'utf8');
    if (!previous.startsWith(marker)) throw new Error('Refusing to replace an existing extension configuration');
  }
  const temporary = path.join(scanDirectory, `.php-darwin-${name}.tmp`);
  let changed = false;
  try {
    if (missing.length) {
      fs.writeFileSync(temporary, (previous || marker) + missing.map(module => `extension=${module}.so\n`).join(''), { flag: 'wx' });
      fs.renameSync(temporary, ini);
      changed = true;
    }
    command(php, ['-r', `exit(${packs[name].map(module => `extension_loaded('${module}')`).join(' && ')} ? 0 : 1);`], { env });
    // Actions imports this for following steps. Standalone users can source the
    // persistent environment file; no shell startup file or service is changed.
    if (Object.keys(environment).length) {
      const exports = Object.entries(environment).map(([variable, value]) => `export ${variable}='${value.replaceAll("'", "'\\''")}'\n`).join('');
      fs.writeFileSync(path.join(destination, 'environment.sh'), exports);
      if (environmentFile) fs.appendFileSync(environmentFile,
        Object.entries(environment).map(([variable, value]) => `${variable}=${value}\n`).join(''));
      else console.log(`Extension environment: ${path.join(destination, 'environment.sh')}`);
    }
  } catch (error) {
    if (changed) {
      if (previous === undefined) fs.rmSync(ini, { force: true });
      else fs.writeFileSync(ini, previous);
    }
    throw error;
  } finally { fs.rmSync(temporary, { force: true }); }
}
async function activate(directory, base, scanDirectory, { installPack = installDownloaded, enablePack = enableInstalled } = {}) {
  validateContext(base);
  const prefix = base.architecture === 'arm64' ? '/opt/homebrew' : '/usr/local';
  const config = base.php_version + (base.build === 'debug' ? '-debug' : '') + (base.thread_safety === 'zts' ? '-zts' : '');
  if (scanDirectory !== `${prefix}/etc/php/${config}/conf.d`) throw new Error('Invalid optional extension configuration directory');
  const names = requestedPacks(directory);
  const installed = await Promise.allSettled(names.map(async name => {
    const entry = readEntry(directory, name);
    validateBase(entry, base);
    await installPack(directory, name);
    return name;
  }));
  const enabled = [];
  // Enable after all independent installations finish, so PHP never reads a
  // half-written configuration or loads a serializer before it is installed.
  for (const [index, result] of installed.entries()) {
    try {
      if (result.status === 'rejected') throw result.reason;
      await enablePack(directory, result.value, scanDirectory);
      enabled.push(result.value);
    } catch (error) {
      console.warn(`Extension cache ${names[index]} unavailable; caller fallback remains available: ${error.message}`);
    }
  }
  return enabled;
}
function phpApi(phpConfig = 'php-config') {
  const include = command(phpConfig, ['--include-dir']);
  const header = fs.readFileSync(path.join(include, 'Zend/zend_modules.h'), 'utf8');
  const match = header.match(/^#define\s+ZEND_MODULE_API_NO\s+(\d{8})\b/m);
  if (!match) throw new Error('Missing PHP module API in installed headers');
  return match[1];
}
function runtimeContext(phpConfig = 'php-config') {
  const version = command(phpConfig, ['--version']);
  if (!/^\d+\.\d+\.\d+(?:[A-Za-z+-][0-9A-Za-z.+-]*)?$/.test(version)) throw new Error('Invalid php-config version');
  const flags = command(phpConfig, ['--configure-options']).replaceAll("'", '').split(/\s+/);
  const enabled = option => flags.includes(option) || flags.includes(option + '=yes');
  return { php_version: version.split('.').slice(0, 2).join('.'), build: enabled('--enable-debug') ? 'debug' : 'release',
    thread_safety: enabled('--enable-zts') || enabled('--enable-maintainer-zts') ? 'zts' : 'nts',
    architecture: process.arch === 'arm64' ? 'arm64' : 'x86_64',
    php_api: phpApi(phpConfig), extension_dir: command(phpConfig, ['--extension-dir']) };
}
function inspectTree(root) {
  function walk(directory) {
    for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, item.name);
      if (item.isSymbolicLink()) {
        const target = fs.readlinkSync(file);
        if (path.isAbsolute(target) || !path.resolve(path.dirname(file), target).startsWith(root + path.sep) ||
            !fs.realpathSync(file).startsWith(fs.realpathSync(root) + path.sep)) throw new Error('Unsafe pack symlink');
      } else if (item.isDirectory()) walk(file);
      else if (!item.isFile()) throw new Error('Unsupported pack member');
    }
  }
  walk(root);
}
function packEnvironment(metadata, destination) {
  const environment = {};
  for (const [name, values] of Object.entries(metadata.environment || {})) {
    if (!['MAGICK_CONFIGURE_PATH', 'MAGICK_CODER_MODULE_PATH', 'MAGICK_FILTER_MODULE_PATH', 'SASL_PATH'].includes(name) ||
        !Array.isArray(values) || !values.every(safePath)) throw new Error('Invalid pack environment');
    environment[name] = values.map(value => path.join(destination, value)).join(path.delimiter);
  }
  return environment;
}
function relocateResources(metadata, stage, destination) {
  if (!Array.isArray(metadata.relocations)) throw new Error('Missing resource relocation metadata');
  for (const relative of metadata.relocations) {
    if (!safePath(relative) || !relative.endsWith('.la')) throw new Error('Unsafe resource relocation');
    const file = path.join(stage, relative);
    if (!fs.lstatSync(file).isFile() || fs.statSync(file).size > 1000000) throw new Error('Invalid resource descriptor');
    const content = fs.readFileSync(file, 'utf8');
    if (!content.includes('@PHP_DARWIN_EXTENSION_ROOT@')) throw new Error('Missing resource relocation marker');
    fs.writeFileSync(file, content.replaceAll('@PHP_DARWIN_EXTENSION_ROOT@', destination));
  }
}
function readEntry(directory, name) {
  if (!Object.hasOwn(packs, name)) throw new Error('Unknown extension pack');
  const entry = validateEntry(JSON.parse(fs.readFileSync(path.join(directory, `${name}.json`), 'utf8')));
  if (entry.name !== name) throw new Error('Extension cache name mismatch');
  return entry;
}
function verifyArchive(directory, entry) {
  const archive = path.join(directory, entry.file);
  const data = fs.readFileSync(archive);
  if (data.length !== entry.bytes || digest(data) !== entry.sha256) throw new Error('Extension archive changed after download');
  return archive;
}
function preparedMetadata(stage, entry) {
  if (!fs.lstatSync(stage).isDirectory()) throw new Error('Invalid extension staging directory');
  inspectTree(stage);
  const metadata = JSON.parse(fs.readFileSync(path.join(stage, 'metadata.json'), 'utf8'));
  if (metadata.schema !== 1 || key(metadata) !== key(entry) || metadata.php_api !== entry.php_api ||
      metadata.inputs_sha256 !== entry.inputs_sha256 || JSON.stringify(metadata.modules) !== JSON.stringify(packs[entry.name])) {
    throw new Error('Extension archive metadata mismatch');
  }
  for (const module of metadata.modules) {
    if (!fs.lstatSync(path.join(stage, 'modules', `${module}.so`)).isFile()) throw new Error('Missing extension module');
  }
  return metadata;
}
function prepareArchive(directory, name) {
  const entry = readEntry(directory, name);
  const archive = verifyArchive(directory, entry);
  const ready = path.resolve(directory, `${name}-${entry.sha256}.stage`);
  const stage = fs.mkdtempSync(path.resolve(directory, `.prepare-${name}-`));
  try {
    const listing = command('tar', ['--zstd', '-tf', archive]).split('\n');
    if (!listing.every(member => safePath(member.replace(/\/$/, '')))) throw new Error('Unsafe extension archive path');
    command('tar', ['--zstd', '--no-same-owner', '-xf', archive, '-C', stage]);
    preparedMetadata(stage, entry);
    fs.renameSync(stage, ready);
    return ready;
  } finally {
    fs.rmSync(stage, { recursive: true, force: true });
  }
}
function prepareDownloaded(directory, name) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [__filename, 'prepare', directory, name], { stdio: 'inherit' });
    child.once('error', reject);
    child.once('exit', code => code === 0 ? resolve() : reject(new Error(`Preparing ${name} failed (${code})`)));
  });
}
function movePrepared(stage, destination) {
  try { fs.renameSync(stage, destination); }
  catch (error) {
    if (error.code !== 'EXDEV') throw error;
    // RUNNER_TEMP may be on another volume. Keep the final move atomic there.
    const local = fs.mkdtempSync(path.join(path.dirname(destination), '.install-'));
    try {
      fs.cpSync(stage, local, { recursive: true, verbatimSymlinks: true });
      fs.renameSync(local, destination);
    } finally { fs.rmSync(local, { recursive: true, force: true }); }
  }
}
function install(directory, name, { phpConfig = 'php-config', php = 'php' } = {}) {
  const started = performance.now();
  const entry = readEntry(directory, name);
  const actual = runtimeContext(phpConfig, php);
  if (entry.name !== name || !['php_version', 'build', 'thread_safety', 'architecture', 'php_api'].every(field => actual[field] === entry[field])) {
    throw new Error('Extension cache does not match installed PHP');
  }
  if (Number(command('sw_vers', ['-productVersion']).split('.')[0]) < entry.minimum_macos) throw new Error('Extension cache requires newer macOS');
  const prefix = actual.architecture === 'arm64' ? '/opt/homebrew' : '/usr/local';
  if (!actual.extension_dir.startsWith(prefix + '/') || !fs.statSync(actual.extension_dir).isDirectory()) throw new Error('Invalid PHP extension directory');
  const stage = path.resolve(directory, `${name}-${entry.sha256}.stage`);
  if (fs.existsSync(stage)) verifyArchive(directory, entry);
  else prepareArchive(directory, name);
  const store = path.join(prefix, 'var/php-darwin/extensions');
  fs.mkdirSync(store, { recursive: true });
  if (fs.realpathSync(store) !== store) throw new Error('Extension store traverses a symlink');
  const destination = path.join(store, entry.sha256);
  const previous = [];
  let committed = false;
  try {
    const metadata = preparedMetadata(stage, entry);
    relocateResources(metadata, stage, destination);
    if (!fs.existsSync(destination)) movePrepared(stage, destination);
    else {
      if (fs.realpathSync(destination) !== destination ||
          fs.readFileSync(path.join(destination, 'metadata.json'), 'utf8') !== fs.readFileSync(path.join(stage, 'metadata.json'), 'utf8')) {
        throw new Error('Installed private extension cache is inconsistent');
      }
      inspectTree(destination);
    }
    // mkdtemp creates a private staging directory. Installed runtime files must
    // also be readable by PHP processes running under another account.
    fs.chmodSync(destination, 0o755);
    const environment = packEnvironment(metadata, destination);
    const args = metadata.modules.flatMap(module => ['-d', `extension=${path.join(destination, 'modules', `${module}.so`)}`]);
    command(php, ['-n', ...args, '-r', `exit(extension_loaded('${name}') ? 0 : 1);`], { env: { ...process.env, ...environment } });
    // Only install modules after the entire private pack loads successfully.
    for (const module of metadata.modules) {
      const target = path.join(actual.extension_dir, `${module}.so`);
      // Serializer modules can already be supplied by the PHP cache or user.
      if (module !== name && fs.existsSync(target)) continue;
      const backup = path.join(directory, `${module}.previous`);
      let hadPrevious = false;
      try { fs.lstatSync(target); fs.renameSync(target, backup); hadPrevious = true; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      previous.push({ target, backup, hadPrevious });
      fs.symlinkSync(path.join(destination, 'modules', `${module}.so`), target);
    }
    const installedArgs = metadata.modules.flatMap(module => ['-d', `extension=${path.join(actual.extension_dir, `${module}.so`)}`]);
    command(php, ['-n', ...installedArgs, '-r', `exit(extension_loaded('${name}') ? 0 : 1);`], { env: { ...process.env, ...environment } });
    fs.writeFileSync(path.join(directory, `${name}.env`), Object.entries(environment).map(([variable, value]) => `${variable}=${value}\n`).join(''));
    fs.writeFileSync(path.join(directory, `${name}.modules`), metadata.modules.join('\n') + '\n');
    committed = true;
    console.log(`Installed ${name} from its separate extension cache in ${((performance.now() - started) / 1000).toFixed(3)} seconds`);
    return { modules: metadata.modules, environment, destination };
  } finally {
    if (!committed) for (const item of previous.reverse()) {
      fs.rmSync(item.target, { force: true });
      if (item.hadPrevious) fs.renameSync(item.backup, item.target);
    }
    else for (const item of previous) if (item.hadPrevious) fs.rmSync(item.backup, { force: true });
    fs.rmSync(stage, { recursive: true, force: true });
  }
}
module.exports = { packs, origins, command, digest, safePath, key, validateContext, validateEntry, phpApi,
  selectRequested, requestedPacks, validateBase, activate, enableInstalled, download, prefetch, runtimeContext, inspectTree, packEnvironment, relocateResources, prepareArchive, movePrepared, install };
if (require.main === module) (async () => {
  const [mode, directory, ...args] = process.argv.slice(2);
  if (!directory) throw new Error('Extension staging directory required');
  if (mode === 'select' && args.length === 1) {
    fs.writeFileSync(path.join(directory, 'requested.txt'), selectRequested(args[0]).join('\n'));
  } else if (mode === 'prefetch-requested' && args.length === 4) {
    const [php_version, build, thread_safety, architecture] = args;
    const names = requestedPacks(directory);
    if (names.length) await prefetch(directory, { php_version, build, thread_safety, architecture }, names);
  } else if (mode === 'activate' && args.length === 2) {
    await activate(directory, JSON.parse(fs.readFileSync(args[0], 'utf8')), args[1]);
  } else if (mode === 'prefetch') {
    const [php_version, build, thread_safety, architecture, ...names] = args;
    await prefetch(directory, { php_version, build, thread_safety, architecture }, names);
  } else if (mode === 'prepare' && args.length === 1) prepareArchive(directory, args[0]);
  else if (mode === 'install' && args.length === 1) install(directory, args[0]);
  else throw new Error('Usage: install-extensions.cjs select|prefetch-requested|activate|prefetch|prepare|install DIRECTORY ...');
})().catch(error => { console.error(`php-darwin extensions: ${error.message}`); process.exitCode = 1; });
PHP_DARWIN_EXTENSION_INSTALLER
}

# Source: scripts/installer/trust-store.sh
php_darwin_trust_store() (


# Exit 78 means that Homebrew must handle this layout/configuration itself.
php_darwin_ruby - "$@" <<'PHP_DARWIN_TRUST_RUBY'
require 'json'
require 'fileutils'
require 'tempfile'

def unsupported
  exit 78
end

def secure_stat(path, directory: false)
  stat = File.lstat(path)
  unsupported if stat.symlink?
  raise "insecure trust path: #{path}" unless stat.uid == Process.euid && (stat.mode & 0022).zero?
  raise "invalid trust path: #{path}" unless directory ? stat.directory? : stat.file? && stat.nlink == 1
  stat
end

def atomic_write(path, contents)
  Tempfile.create(['.php-darwin-trust-', '.tmp'], File.dirname(path)) do |file|
    file.chmod(0600)
    file.write(contents)
    file.flush
    file.fsync
    File.rename(file.path, path)
  end
end

def read_store(path)
  return {} unless File.exist?(path) || File.symlink?(path)
  secure_stat(path)
  store = JSON.parse(File.read(path))
  # Unknown schemas belong to Homebrew. Never repair or replace malformed JSON.
  unsupported unless store.is_a?(Hash) && (store.keys - %w[trustedtaps trustedformulae trustedcasks trustedcommands]).empty?
  unsupported unless store.values.all? { |entries| entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(String) } }
  store
end

journal_written = false
store_written = false
begin
  mode, prefix, tap, journal, *references = ARGV
  raise 'invalid trust operation' unless %w[snapshot add remove].include?(mode)
  unsupported if Process.euid.zero? || ENV['HOMEBREW_FORCE_BREW_WRAPPER'] || ENV['HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY']
  repository = File.dirname(File.dirname(File.realpath(File.join(prefix, 'bin/brew'))))
  source_path = File.join(repository, 'Library/Homebrew/trust.rb')
  unsupported unless File.file?(source_path)
  source = File.read(source_path)
  # Only the JSON storage protocol with Homebrew's flock/atomic-write contract
  # is supported. Unrecognized storage implementations use the CLI instead.
  protocol = {
    'trust_file' => ['HOMEBREW_USER_CONFIG_HOME', '.homebrew/trust.json', 'user_config_home/"trust.json"'],
    'setting_key' => ['SETTING_KEYS.fetch(type).to_s'],
    'normalise_name' => ['name.downcase'],
    'trust_store' => ['JSON.parse(trust_path.read)', 'parsed_store.transform_values'],
    'write_trust_store' => ['write_path.atomic_write', 'write_path.chmod(0600)'],
    'with_trust_store_lock' => ['"#{trust_file}.lock"', 'File::RDWR | File::CREAT, 0600', 'lock_file.flock(File::LOCK_EX)']
  }
  protocol.each do |name, markers|
    method = source[/^    def self\.#{name}\b.*?^    end$/m]
    unsupported unless method && markers.all? { |marker| method.include?(marker) }
  end
  %w[tap:trustedtaps formula:trustedformulae cask:trustedcasks command:trustedcommands].each do |mapping|
    type, key = mapping.split(':')
    unsupported unless source.match?(/#{type}:\s+:#{key}\b/)
  end
  config_base = [ENV['XDG_CONFIG_HOME'], ENV['HOMEBREW_XDG_CONFIG_HOME']].find { |value| value && !value.empty? }
  config = config_base ? File.join(config_base, 'homebrew') : File.join(ENV.fetch('HOME'), '.homebrew')
  unsupported unless config.start_with?('/')
  # brew.env may redirect Homebrew or its config. Let brew resolve those files.
  ['/etc/homebrew/brew.env', File.join(prefix, 'etc/homebrew/brew.env'), File.join(config, 'brew.env')].each do |path|
    unsupported if File.exist?(path) || File.symlink?(path)
  end
  path = File.join(config, 'trust.json')
  secure_stat(config, directory: true) if File.exist?(config) || File.symlink?(config)
  if mode == 'snapshot'
    store = read_store(path)
    puts JSON.generate({ 'taps' => store.fetch('trustedtaps', []).map(&:downcase),
                         'formulae' => store.fetch('trustedformulae', []).map(&:downcase) })
    exit 0
  end
  raise 'invalid formula trust references' unless tap.match?(/\A[a-z0-9_.-]+\/[a-z0-9_.-]+\z/) &&
    references.all? { |name| name.start_with?(tap + '/') && name.match?(/\A[a-z0-9_.-]+\/[a-z0-9_.-]+\/[a-z0-9@+_.-]+\z/) }
  if mode == 'add'
    user, name = tap.split('/')
    tap_path = File.join(repository, 'Library/Taps', user, 'homebrew-' + name)
    origin = IO.popen(['git', '-C', tap_path, 'remote', 'get-url', 'origin'], &:read).strip.delete_suffix('.git')
    unsupported unless $?.success? && origin == "https://github.com/#{user}/homebrew-#{name}"
    references.each do |reference|
      formula = File.join(tap_path, 'Formula', reference.split('/').last + '.rb')
      unsupported unless File.file?(formula) && !File.symlink?(formula)
    end
  end
  FileUtils.mkdir_p(config, mode: 0700) unless File.exist?(config)
  secure_stat(config, directory: true)
  lock_path = path + '.lock'
  secure_stat(lock_path) if File.exist?(lock_path) || File.symlink?(lock_path)
  File.open(lock_path, File::RDWR | File::CREAT, 0600) do |lock|
    stat = secure_stat(lock_path)
    raise 'trust lock changed' unless stat.ino == lock.stat.ino && stat.dev == lock.stat.dev
    lock.flock(File::LOCK_EX)
    store = read_store(path)
    entries = store.fetch('trustedformulae', [])
    if mode == 'add'
      delta = references.uniq - entries.map(&:downcase)
      delta = [] if store.fetch('trustedtaps', []).map(&:downcase).include?(tap)
      # Record the delta under the same lock as the merge, including additions
      # by another process since the installer's initial trust snapshot.
      atomic_write(journal, delta.map { |entry| entry + "\n" }.join)
      journal_written = true
      unless delta.empty?
        store['trustedformulae'] = (entries + delta).sort
        atomic_write(path, JSON.pretty_generate(store) + "\n")
        store_written = true
      end
    else
      remaining = entries.reject { |entry| references.include?(entry.downcase) }
      unless entries == remaining
        remaining.empty? ? store.delete('trustedformulae') : store['trustedformulae'] = remaining
        if store.empty?
          File.unlink(path)
        else
          atomic_write(path, JSON.pretty_generate(store) + "\n")
        end
      end
    end
  end
rescue SystemCallError, JSON::ParserError, RuntimeError, ArgumentError, KeyError => error
  File.unlink(journal) if journal_written && !store_written && File.file?(journal)
  warn "php-darwin: trust store: #{error.message}"
  exit 1
end
PHP_DARWIN_TRUST_RUBY
)

# Source: scripts/installer/check-dependencies.sh
php_darwin_check_dependencies() (


php_darwin_ruby - "$@" <<'PHP_DARWIN_DEPENDENCIES_RUBY'
require 'json'
begin
  prefix, packages = ARGV
  dependencies = []
  File.foreach(packages) do |line|
    name, target, keg_only, extra = line.strip.split("\t")
    raise 'invalid package receipt path' unless extra.nil? && %w[true false].include?(keg_only) &&
      name.match?(/\A[a-zA-Z0-9@+_.-]+\z/) && target.match?(%r{\A\.\./Cellar/#{Regexp.escape(name)}/[^/\s]+\z})
    receipt = File.join(prefix, target.delete_prefix('../'), 'INSTALL_RECEIPT.json')
    exit 78 unless File.file?(receipt)
    data = JSON.parse(File.read(receipt))
    entries = data['runtime_dependencies']
    exit 78 unless entries.is_a?(Array)
    entries.each do |entry|
      exit 78 unless entry.is_a?(Hash) && entry['full_name'].is_a?(String)
      dependency = entry['full_name'].split('/').last
      raise 'invalid runtime dependency name' unless dependency && !%w[. ..].include?(dependency) && dependency.match?(/\A[a-zA-Z0-9@+_.-]+\z/)
      dependencies << dependency
    end
  end
  # Homebrew's missing_dependencies uses installed receipt data, not current
  # formula definitions. Check every cached package, including transitive deps.
  missing = dependencies.uniq.sort.reject do |name|
    File.directory?(File.join(prefix, 'Cellar', name)) || File.directory?(File.join(prefix, 'opt', name))
  end
  unless missing.empty?
    puts missing.join(' ')
    exit 1
  end
rescue SystemCallError, JSON::ParserError, RuntimeError, ArgumentError => error
  warn "php-darwin: dependency receipts: #{error.message}"
  exit 1
end
PHP_DARWIN_DEPENDENCIES_RUBY
)

# Source: scripts/installer/unlink-kegs.sh
php_darwin_unlink_kegs() (


php_darwin_ruby - "$@" <<'PHP_DARWIN_UNLINK_RUBY'
require 'json'
require 'find'
require 'fileutils'
require 'tempfile'

def unsupported
  exit 78
end

def resolved(path)
  File.symlink?(path) ? File.expand_path(File.readlink(path), File.dirname(path)) : path
end

def parents_safe(prefix, path)
  parent = File.dirname(path)
  until parent == prefix
    raise "unsafe unlink parent: #{parent}" if File.symlink?(parent)
    raise 'unlink path outside Homebrew' unless parent.start_with?(prefix + '/')
    parent = File.dirname(parent)
  end
end

def acquire_lock(prefix, name, locks)
  raise 'invalid formula lock name' unless !%w[. ..].include?(name) && name.match?(/\A[a-zA-Z0-9@+_.-]+\z/)
  lock_path = File.join(prefix, 'var/homebrew/locks', name + '.formula.lock')
  parents_safe(prefix, lock_path)
  FileUtils.mkdir_p(File.dirname(lock_path))
  unsupported if File.symlink?(lock_path)
  file = File.open(lock_path, File::RDWR | File::CREAT, 0644)
  locks << file
  raise "Homebrew formula is busy: #{name}" unless file.flock(File::LOCK_EX | File::LOCK_NB)
  raise 'Homebrew formula lock changed' unless file.stat.ino == File.stat(lock_path).ino
end

locks = []
begin
  mode, prefix, journal_dir, *names = ARGV
  raise 'invalid unlink operation' unless %w[unlink restore].include?(mode)
  unsupported unless File.realpath(prefix) == prefix
  if mode == 'restore'
    journals = Dir.glob(File.join(journal_dir, '*.json')).sort.reverse
    restored_names = journals.flat_map do |journal|
      JSON.parse(File.read(journal)).flat_map do |entry|
        path = File.join(prefix, entry.fetch('path'))
        target = File.expand_path(entry.fetch('target'), File.dirname(path))
        match = target.match(%r{\A#{Regexp.escape(prefix)}/Cellar/([^/]+)/})
        raise 'invalid unlink journal target' unless match
        names = [match[1]]
        names << File.basename(path) if File.dirname(path) == File.join(prefix, 'opt') ||
          File.dirname(path) == File.join(prefix, 'var/homebrew/linked')
        names
      end
    end
    restored_names.uniq.sort.each { |name| acquire_lock(prefix, name, locks) }
    journals.each do |journal|
      JSON.parse(File.read(journal)).reverse_each do |entry|
        relative, target = entry.values_at('path', 'target')
        raise 'invalid unlink journal' unless relative.is_a?(String) && target.is_a?(String) &&
          relative.match?(%r{\A(?:(?:bin|etc|include|lib|sbin|share|var)/|opt/[^/]+\z)}) &&
          !relative.match?(%r{(?:\A|/)\.\.?(/|\z)|//|[\r\n\t]}) &&
          File.expand_path(target, File.dirname(File.join(prefix, relative))).start_with?(prefix + '/Cellar/')
        path = File.join(prefix, relative)
        parents_safe(prefix, path)
        if File.symlink?(path)
          raise "unlink rollback conflict: #{path}" unless File.readlink(path) == target
          next
        end
        if File.directory?(path)
          # Cache extraction may have replaced an old directory symlink with
          # real directories. Remove only empty directories, never user files.
          directories = []
          Find.find(path) do |child|
            raise "unlink rollback conflict: #{child}" unless File.directory?(child) && !File.symlink?(child)
            directories << child
          end
          directories.reverse_each { |directory| Dir.rmdir(directory) }
        end
        raise "unlink rollback conflict: #{path}" if File.exist?(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.symlink(target, path)
      end
      File.unlink(journal)
    end
    exit 0
  end
  names = names.map { |name| name.split('/').last }.uniq
  unsupported if names.empty?
  raise 'invalid formula name' unless names.all? { |name| !%w[. ..].include?(name) && name.match?(/\A[a-zA-Z0-9@+_.-]+\z/) }
  selected_paths = nil
  if ENV['PHP_DARWIN_UNLINK_PATHS_FILE']
    selected_paths = {}
    File.readlines(ENV.fetch('PHP_DARWIN_UNLINK_PATHS_FILE'), chomp: true).each do |relative|
      raise 'invalid selected unlink path' unless relative.match?(%r{\A(?:bin|etc|include|lib|opt|sbin|share|var)/}) &&
        !relative.match?(%r{(?:\A|/)\.\.?(/|\z)|//|[\r\n\t]}) && !relative.end_with?('/')
      path = File.join(prefix, relative)
      until path == prefix
        selected_paths[path] = true
        path = File.dirname(path)
      end
    end
  end
  begin
    acquire = lambda { |name| acquire_lock(prefix, name, locks) }
    names.sort.each { |name| acquire.call(name) }
    plans = []
    additional_locks = []
    names.each do |name|
      record = File.join(prefix, 'var/homebrew/linked', name)
      parents_safe(prefix, record)
      unsupported unless File.symlink?(record)
      keg = resolved(record)
      unsupported unless keg.match?(%r{\A#{Regexp.escape(prefix)}/Cellar/#{Regexp.escape(name)}/[^/]+\z}) &&
        File.directory?(keg) && !File.symlink?(keg)
      parents_safe(prefix, keg)
      opt = File.join(prefix, 'opt', name)
      parents_safe(prefix, opt)
      unsupported if File.exist?(opt) && resolved(opt) != keg
      receipt = JSON.parse(File.read(File.join(keg, 'INSTALL_RECEIPT.json')))
      aliases = receipt['aliases'] || []
      unsupported unless aliases.is_a?(Array) && aliases.all? { |value| value.is_a?(String) && !%w[. ..].include?(value) && value.match?(/\A[a-zA-Z0-9@+_.-]+\z/) }
      # Homebrew removes unversioned aliases of this keg during unlink. Record
      # only direct, owned aliases; unusual layouts still use the native command.
      aliases.reject { |value| value.include?('@') }.each do |value|
        %w[opt var/homebrew/linked].each do |directory|
          alias_path = File.join(prefix, directory, value)
          next unless File.exist?(alias_path) || File.symlink?(alias_path)
          unsupported unless File.symlink?(alias_path)
          target = resolved(alias_path)
          # A link to another installed keg is left alone, as Homebrew does.
          next if File.exist?(alias_path) && File.realpath(alias_path) != keg
          unsupported unless target.match?(%r{\A#{Regexp.escape(prefix)}/Cellar/#{Regexp.escape(name)}/[^/]+\z})
          additional_locks << value
          plans << {'path' => alias_path.delete_prefix(prefix + '/'), 'target' => File.readlink(alias_path)}
        end
      end
      Dir.glob(opt + '@*').each do |alias_path|
        next if aliases.include?(File.basename(alias_path))
        unsupported unless File.symlink?(alias_path)
        target = resolved(alias_path)
        if !File.exist?(alias_path)
          # php@8.5-debug can be a stale alias of the independent php-debug
          # rack. It must not force native unlinking of the active php rack.
          unsupported unless target.match?(%r{\A#{Regexp.escape(prefix)}/Cellar/[^/]+/[^/]+\z})
          unsupported if File.dirname(target) == File.dirname(keg)
        else
          unsupported if File.dirname(File.realpath(alias_path)) == File.dirname(keg)
        end
      end
      tap = receipt.dig('source', 'tap')
      if tap.is_a?(String)
        old_tap_opt = File.join(prefix, 'opt', tap.split('/').first)
        unsupported if File.directory?(old_tap_opt) && !File.symlink?(old_tap_opt)
      end
      Dir.glob(File.join(prefix, 'opt', '*')).each do |alias_path|
        next unless File.symlink?(alias_path) && File.directory?(alias_path)
        if File.dirname(resolved(alias_path)) == File.dirname(keg)
          additional_locks << File.basename(alias_path)
        end
      end
      %w[bin etc include lib sbin share var].each do |directory|
        root = File.join(keg, directory)
        next unless File.exist?(root)
        Find.find(root) do |source|
          destination = File.join(prefix, source.delete_prefix(keg + '/'))
          # Dependency upgrades only replace paths supplied by this archive.
          # Keep old documentation and other links to the preserved old keg.
          if selected_paths && !selected_paths.key?(destination)
            Find.prune
          end
          if File.symlink?(destination)
            if resolved(destination) == source
              unsupported if destination.match?(%r{info/(?:[^.].*?\.info(?:\.gz)?|dir)\z})
              plans << {'path' => destination.delete_prefix(prefix + '/'), 'target' => File.readlink(destination)}
              Find.prune if File.directory?(source)
            elsif File.directory?(source)
              unsupported
            end
          elsif !File.directory?(destination) && File.directory?(source)
            Find.prune
          end
        end
      end
      plans << {'path' => record.delete_prefix(prefix + '/'), 'target' => File.readlink(record)}
    end
    (additional_locks.uniq - names).sort.each { |name| acquire.call(name) }
    plans.uniq!
    plans.each do |entry|
      path = File.join(prefix, entry['path'])
      parents_safe(prefix, path)
      raise "Homebrew link changed: #{path}" unless File.symlink?(path) && File.readlink(path) == entry['target']
    end
    FileUtils.mkdir_p(journal_dir, mode: 0700)
    stamp = format('%020d-%d', Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond), Process.pid)
    Tempfile.create(['unlink-', '.tmp'], journal_dir) do |file|
      file.write(JSON.generate(plans))
      file.flush
      file.fsync
      File.rename(file.path, File.join(journal_dir, stamp + '.json'))
    end
    plans.each { |entry| File.unlink(File.join(prefix, entry['path'])) }
  end
rescue SystemCallError, JSON::ParserError, RuntimeError, ArgumentError, TypeError, KeyError => error
  warn "php-darwin: Homebrew links: #{error.message}"
  exit 1
ensure
  locks.reverse_each(&:close)
end
PHP_DARWIN_UNLINK_RUBY
)

# Source: scripts/installer/php-command-links.sh
php_darwin_php_command_links() (


php_darwin_ruby - "$@" <<'PHP_DARWIN_COMMAND_LINKS_RUBY'
require 'json'
require 'fileutils'

begin
  mode, prefix, journal, links_file, formula = ARGV
  commands = %w[bin/php bin/php-config bin/phpize sbin/php-fpm]
  raise 'unsafe Homebrew command directory' if %w[bin sbin].any? { |name| File.symlink?(File.join(prefix, name)) }
  case mode
  when 'prepare'
    entries = File.readlines(links_file, chomp: true).map do |line|
      relative, target = line.split("\t", -1)
      next unless commands.include?(relative)
      expected = File.expand_path(target, File.dirname(File.join(prefix, relative)))
      raise 'invalid archived PHP command' unless expected.start_with?(File.join(prefix, 'Cellar', formula) + '/')
      destination = File.join(prefix, relative)
      next unless File.exist?(destination) || File.symlink?(destination)
      raise "PHP command conflicts with an unmanaged file: #{destination}" unless File.symlink?(destination)
      previous = File.readlink(destination)
      resolved = File.expand_path(previous, File.dirname(destination))
      raise "PHP command conflicts with an unmanaged link: #{destination}" unless
        resolved.match?(%r{\A#{Regexp.escape(prefix)}/(?:Cellar|opt)/php(?:@[0-9.]+)?(?:-debug)?(?:-zts)?/})
      {'path' => relative, 'previous' => previous, 'installed' => target}
    end
    entries.compact!
    # Persist the complete plan before removing any link. Extraction supplies
    # the new default; this helper never discovers the version by running PHP.
    File.open(journal, 'w', 0600) { |file| file.write(JSON.generate(entries)); file.flush; file.fsync }
    entries.each { |entry| File.unlink(File.join(prefix, entry.fetch('path'))) }
  when 'restore'
    exit 0 unless File.file?(journal)
    JSON.parse(File.read(journal)).reverse_each do |entry|
      relative, previous, installed = entry.values_at('path', 'previous', 'installed')
      raise 'invalid command link journal' unless commands.include?(relative) && previous.is_a?(String) && installed.is_a?(String)
      destination = File.join(prefix, relative)
      if File.symlink?(destination)
        target = File.readlink(destination)
        next if target == previous
        raise "PHP command rollback conflict: #{destination}" unless target == installed
        File.unlink(destination)
      end
      raise "PHP command rollback conflict: #{destination}" if File.exist?(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      File.symlink(previous, destination)
    end
    File.unlink(journal)
  else
    raise 'invalid PHP command link operation'
  end
rescue SystemCallError, JSON::ParserError, RuntimeError, ArgumentError, TypeError => error
  warn "php-darwin: #{error.message}"
  exit 1
end
PHP_DARWIN_COMMAND_LINKS_RUBY
)

# Source: scripts/installer/read-metadata.sh
php_darwin_read_metadata() (

archive=${1:?}
member=${2:?}
output=${3:?}

[ -f "$archive" ] || {
  printf 'Archive not found: %s\n' "$archive" >&2
  exit 1
}
[[ "$member" =~ ^var/php-darwin/php_[0-9]+\.[0-9]+-(nts|zts)-(debug|release)\+darwin_(arm64|x86_64)\.json$ ]] || {
  printf 'Unsafe metadata member: %s\n' "$member" >&2
  exit 1
}
# Metadata is the first member. Stop as soon as tar has read it instead of
# decompressing every keg. The caller authenticates the entire archive first.
# zstd -f also passes through plain tar input used by validation fixtures.
case "$(tar --version)" in
  *bsdtar*) metadata_options=(-q) ;;
  *) metadata_options=(--occurrence=1) ;;
esac
zstd -qdcf "$archive" 2> "$output.zstd.log" | \
  tar --ignore-zeros -xOf - "${metadata_options[@]}" "$member" > "$output"
metadata_status=("${PIPESTATUS[@]}")
# Some zstd versions handle EPIPE themselves and return their write-error code
# instead of SIGPIPE. Accept only that diagnostic after tar read the full member.
if [ "${metadata_status[0]}" -eq 70 ] && \
  grep -Eq '^zstd: error 70 : Write error : .*Broken pipe *$' "$output.zstd.log"; then
  metadata_status[0]=141
fi
if [ "${metadata_status[1]}" -ne 0 ] || \
  { [ "${metadata_status[0]}" -ne 0 ] && [ "${metadata_status[0]}" -ne 141 ]; }; then
  cat "$output.zstd.log" >&2
  rm -f "$output.zstd.log" "$output"
  exit 1
fi
rm -f "$output.zstd.log"
if [ ! -s "$output" ]; then
  rm -f "$output"
  exit 1
fi
)

# Source: scripts/lib/source-hash.sh
php_darwin_source_hash() (


version=${1:?}
tap_path=${HOMEBREW_PHP_PATH:-}
php_darwin_validate_version "$version"
repository=$(php_darwin_package_config tap_repository)
branch=$(php_darwin_package_config tap_branch)
tmp_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-source.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
hashes="$tmp_dir/formulae.tsv"

while read -r build ts; do
  formula=$(php_darwin_formula "$version" "$build" "$ts") || exit 1
  formula_file="$tmp_dir/$formula.rb"
  if [ -n "$tap_path" ]; then
    cp "$tap_path/Formula/$formula.rb" "$formula_file" || php_darwin_die "could not read $formula from the local tap"
  else
    curl --retry 2 --retry-all-errors -fsSL \
      "${repository/github.com/raw.githubusercontent.com}/$branch/Formula/$formula.rb" \
      -o "$formula_file" || php_darwin_die "could not download $formula"
  fi
  formula_hash=$(php_darwin_sha256 "$formula_file") || php_darwin_die "could not hash $formula"
  printf '%s\t%s\n' "$formula" "$formula_hash" >> "$hashes" || php_darwin_die 'could not record a formula hash'
done < <(php_darwin_configured_variants)

LC_ALL=C sort -u "$hashes" -o "$hashes" || php_darwin_die 'could not sort formula hashes'
php_darwin_sha256 "$hashes" || php_darwin_die 'could not hash formula metadata'
)

# Source: scripts/installer/validate-tap.sh
php_darwin_validate_tap() (


tap_path=${1:?}
version=${2:?}
expected_hash=${3:-}
repository=${4:?}
expected_commit=${5:-}
expected_branch=${6:-}
require_clean=${7:-false}

php_darwin_is_git_worktree "$tap_path" || {
  printf 'Homebrew tap is not a Git repository: %s\n' "$tap_path" >&2
  exit 1
}
actual_repository=$(git -C "$tap_path" remote get-url origin) || {
  printf 'Could not resolve the Homebrew tap origin\n' >&2
  exit 1
}
actual_repository=${actual_repository%.git}
[ "$actual_repository" = "${repository%.git}" ] || {
  printf 'Homebrew tap origin mismatch: %s\n' "$actual_repository" >&2
  exit 1
}
if [ -n "$expected_commit" ]; then
  actual_commit=$(git -C "$tap_path" rev-parse HEAD) || {
    printf 'Could not resolve the Homebrew tap commit\n' >&2
    exit 1
  }
  [ "$actual_commit" = "$expected_commit" ] || {
    printf 'Homebrew tap commit mismatch: %s\n' "$actual_commit" >&2
    exit 1
  }
fi
if [ -n "$expected_branch" ]; then
  actual_branch=$(git -C "$tap_path" symbolic-ref --short HEAD) || {
    printf 'Could not resolve the Homebrew tap branch\n' >&2
    exit 1
  }
  [ "$actual_branch" = "$expected_branch" ] || {
    printf 'Homebrew tap branch mismatch: %s\n' "$actual_branch" >&2
    exit 1
  }
  remote_commit=$(git -C "$tap_path" rev-parse "refs/remotes/origin/$expected_branch") || {
    printf 'Could not resolve the Homebrew tap remote branch\n' >&2
    exit 1
  }
  [ "$remote_commit" = "$expected_commit" ] || {
    printf 'Homebrew tap remote branch does not match its snapshot commit\n' >&2
    exit 1
  }
fi
if [ -n "$expected_hash" ]; then
  actual_hash=$(HOMEBREW_PHP_PATH="$tap_path" php_darwin_source_hash "$version") || {
    printf 'Could not hash the Homebrew tap formulae\n' >&2
    exit 1
  }
  [ "$actual_hash" = "$expected_hash" ] || {
    printf 'Homebrew tap formula hash mismatch\n' >&2
    exit 1
  }
fi
if [ -n "$expected_branch" ] || [ -n "$expected_hash" ] || [ "$require_clean" = true ]; then
  tap_status=$(git -C "$tap_path" status --porcelain --untracked-files=all) || {
    printf 'Could not inspect Homebrew tap status\n' >&2
    exit 1
  }
  [ -z "$tap_status" ] || {
    printf 'Homebrew tap snapshot has changed or untracked files\n' >&2
    exit 1
  }
fi
[ -z "$expected_hash" ] || printf '%s\n' "$actual_hash"
)

# Source: scripts/installer/tap-action.sh
php_darwin_tap_action() (


tap_path=${1:?}
cached_tap_path=${2:?}
version=${3:?}
expected_hash=${4:?}
repository=${5:?}
cached_commit=${6:?}
expected_branch=${7:?}

php_darwin_validate_tap "$tap_path" "$version" '' "$repository" \
  >/dev/null || exit 1
actual_hash=$(HOMEBREW_PHP_PATH="$tap_path" php_darwin_source_hash "$version" 2>/dev/null) || \
  actual_hash=
formula_status=$(git -C "$tap_path" status --porcelain --untracked-files=all -- Formula 2>/dev/null) || {
  printf 'Could not inspect Homebrew tap formula status\n' >&2
  exit 1
}
formula_status=$(awk 'substr($0, 1, 3) == "?? " && $0 ~ /(^|\/)\.DS_Store$/ { next } { print }' \
  <<< "$formula_status") || {
  printf 'Could not filter Homebrew tap formula status\n' >&2
  exit 1
}
if [ "$actual_hash" = "$expected_hash" ] && [ -z "$formula_status" ]; then
  printf 'keep\n'
  exit 0
fi

if ! git -C "$tap_path" diff --quiet -- . || ! git -C "$tap_path" diff --cached --quiet -- .; then
  printf 'Remove changes from %s or untap %s before retrying the cache install\n' "$tap_path" \
    "$(php_darwin_package_config tap)" >&2
  exit 1
fi
untracked_paths=$(git -C "$tap_path" ls-files --others --exclude-standard) || {
  printf 'Could not inspect untracked Homebrew tap files\n' >&2
  exit 1
}
untracked_path=
while IFS= read -r candidate_path; do
  case "$candidate_path" in .DS_Store|*/.DS_Store) ;; *) untracked_path=$candidate_path; break ;; esac
done <<< "$untracked_paths"
[ -z "$untracked_path" ] || {
  printf 'Remove changes from %s or untap %s before retrying the cache install\n' "$tap_path" \
    "$(php_darwin_package_config tap)" >&2
  exit 1
}
existing_commit=$(git -C "$tap_path" rev-parse HEAD) || {
  printf 'Could not resolve the installed Homebrew tap commit\n' >&2
  exit 1
}
actual_cached_commit=$(git -C "$cached_tap_path" rev-parse HEAD) || {
  printf 'Could not resolve the cached Homebrew tap commit\n' >&2
  exit 1
}
[ "$actual_cached_commit" = "$cached_commit" ] || {
  printf 'Cached Homebrew tap commit does not match the archive metadata\n' >&2
  exit 1
}
snapshot_commit=$(git -C "$tap_path" config --get php-darwin.snapshot-commit 2>/dev/null) || \
  snapshot_commit=
if [ -z "$snapshot_commit" ] || [ "$snapshot_commit" != "$existing_commit" ]; then
  existing_branch=$(git -C "$tap_path" symbolic-ref --short HEAD 2>/dev/null) || {
    printf 'Homebrew tap formula hash mismatch on a detached checkout; run brew untap %s before retrying\n' \
      "$(php_darwin_package_config tap)" >&2
    exit 1
  }
  remote_commit=$(git -C "$tap_path" rev-parse "refs/remotes/origin/$expected_branch" 2>/dev/null) || {
    printf 'Homebrew tap formula hash mismatch without an origin/%s reference; run brew untap %s before retrying\n' \
      "$expected_branch" "$(php_darwin_package_config tap)" >&2
    exit 1
  }
  standard_checkout=false
  if [ "$existing_branch" = "$expected_branch" ]; then
    if [ "$remote_commit" = "$existing_commit" ] || \
      git -C "$tap_path" merge-base --is-ancestor "$existing_commit" "$remote_commit" 2>/dev/null; then
      standard_checkout=true
    fi
  fi
  [ "$standard_checkout" = true ] || {
    printf 'Homebrew tap has local commits or a nonstandard branch; run brew untap %s before retrying\n' \
      "$(php_darwin_package_config tap)" >&2
    exit 1
  }
  if [ -n "$snapshot_commit" ]; then
    printf 'Homebrew updated the cached tap; preserving it and using the requested snapshot temporarily\n' >&2
  fi
  printf 'temporary\n'
  exit 0
fi
[ "$existing_commit" != "$cached_commit" ] || {
  printf 'Homebrew tap source hash differs at the same cache snapshot commit\n' >&2
  exit 1
}

# Both snapshots are already present locally. Never make a network request to
# order them: shallow histories may be incomplete, in which case preserve the
# installed tap and use the requested snapshot only for this transaction.
if git -C "$cached_tap_path" merge-base --is-ancestor "$existing_commit" "$cached_commit" 2>/dev/null || \
  git -C "$tap_path" merge-base --is-ancestor "$existing_commit" "$cached_commit" 2>/dev/null; then
  printf 'replace\n'
else
  printf 'temporary\n'
fi
)

# Source: scripts/installer/verify-links.sh
php_darwin_verify_links() (

prefix=${1:?}
verify_links_file=${2:?}
actual_links=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-links.XXXXXX") || exit 1
raw_links=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-raw-links.XXXXXX") || {
  rm -f "$actual_links"
  exit 1
}
trap 'rm -f "$actual_links" "$raw_links"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ -d "$prefix" ] || {
  printf 'Missing Homebrew prefix: %s\n' "$prefix" >&2
  exit 1
}
[ -s "$verify_links_file" ] || {
  printf 'Missing Homebrew link manifest: %s\n' "$verify_links_file" >&2
  exit 1
}

link_paths=()
while IFS=$'\t' read -r link_relative link_target extra; do
  [ -n "$link_relative" ] && [ -n "$link_target" ] && [ -z "$extra" ] || {
    printf 'Invalid Homebrew link record: %s\n' "$link_relative" >&2
    exit 1
  }
  [ -L "$prefix/$link_relative" ] || {
    printf 'Cached Homebrew link is missing or conflicted: %s\n' "$link_relative" >&2
    exit 1
  }
  link_paths+=("$prefix/$link_relative")
done < "$verify_links_file"

if [ "$(uname -s)" = Darwin ]; then
  stat -f $'%N\t%Y' "${link_paths[@]}" > "$raw_links" || exit 1
  awk -F '\t' -v prefix="$prefix/" '
    index($1, prefix) == 1 && NF == 2 { print substr($1, length(prefix) + 1) "\t" $2; next }
    { exit 1 }
  ' "$raw_links" > "$actual_links" || exit 1
else
  : > "$actual_links" || exit 1
  while IFS=$'\t' read -r link_relative link_target extra; do
    printf '%s\t%s\n' "$link_relative" "$(readlink "$prefix/$link_relative")" >> "$actual_links" || exit 1
  done < "$verify_links_file"
fi

if ! cmp -s "$verify_links_file" "$actual_links"; then
  diff -u "$verify_links_file" "$actual_links" >&2 || true
  printf 'Cached Homebrew links do not match the archive manifest\n' >&2
  exit 1
fi
)

# Source: scripts/installer/existing-paths.sh
php_darwin_existing_paths() (

prefix=${1:?}
output=${2:?}
roots_file=${3:?}
kegs_output=${4:?}
managed_paths_file=${5:?}
package_kegs_file=${6:?}

[ -d "$prefix" ] || {
  printf 'Missing Homebrew prefix: %s\n' "$prefix" >&2
  exit 1
}
[ -f "$roots_file" ] || {
  printf 'Missing archive roots: %s\n' "$roots_file" >&2
  exit 1
}
[ -f "$managed_paths_file" ] || {
  printf 'Missing managed archive paths: %s\n' "$managed_paths_file" >&2
  exit 1
}
[ -f "$package_kegs_file" ] || {
  printf 'Missing package keg paths: %s\n' "$package_kegs_file" >&2
  exit 1
}

append_exclusion() {
  relative_path=$1
  case "$relative_path" in *$'\n'*|*$'\r'*)
    printf 'Unsupported Homebrew path: %s\n' "$relative_path" >&2
    exit 1
    ;;
  esac
  printf '%s\n' "$relative_path" >> "$output" || exit 1
}

: > "$output" || exit 1
: > "$kegs_output" || exit 1
allowed_roots=
while IFS= read -r managed_dir extra; do
  [ -n "$managed_dir" ] || continue
  case "$managed_dir" in \#*) continue ;; esac
  [ -z "$extra" ] || {
    printf 'Invalid archive root: %s %s\n' "$managed_dir" "$extra" >&2
    exit 1
  }
  case "$managed_dir" in Cellar|Frameworks|bin|etc|include|lib|opt|sbin|share|var) ;; *)
    printf 'Unsafe archive root: %s\n' "$managed_dir" >&2
    exit 1
    ;;
  esac
  [ ! -L "$prefix/$managed_dir" ] || {
    printf 'Homebrew archive root is a symlink: %s\n' "$managed_dir" >&2
    exit 1
  }
  allowed_roots="$allowed_roots $managed_dir"
done < "$roots_file"

# The archive only contains kegs named in its package metadata. Inventory
# existing versions for those formulae instead of walking the entire Cellar.
while IFS= read -r package_keg extra; do
  [ -n "$package_keg" ] || continue
  [ -z "$extra" ] && [[ "$package_keg" =~ ^Cellar/[A-Za-z0-9@+._-]+/[^/[:space:]]+$ ]] || {
    printf 'Unsafe package keg path: %s %s\n' "$package_keg" "$extra" >&2
    exit 1
  }
  package_rack=${package_keg%/*}
  [ ! -L "$prefix/$package_rack" ] || {
    printf 'Homebrew formula rack is a symlink: %s\n' "$package_rack" >&2
    exit 1
  }
  if [ -d "$prefix/$package_rack" ]; then
    for existing_keg in "$prefix/$package_rack"/*; do
      [ -d "$existing_keg" ] && [ ! -L "$existing_keg" ] || continue
      existing_keg=${existing_keg#"$prefix"/}
      case "$existing_keg" in *$'\n'*|*$'\r'*|*$'\t'*)
        printf 'Unsupported Homebrew keg path: %s\n' "$existing_keg" >&2
        exit 1
        ;;
      esac
      printf '%s\n' "$existing_keg" >> "$kegs_output" || exit 1
    done
  fi
  if [ -e "$prefix/$package_keg" ] || [ -L "$prefix/$package_keg" ]; then
    append_exclusion "$package_keg"
  fi
done < "$package_kegs_file"

inventory_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-existing.XXXXXX") || exit 1
trap 'rm -rf "$inventory_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# Check each shared file and each distinct ancestor once in native stat. A
# shell lstat/regex loop over thousands of links dominates installs on Intel.
awk -v prefix="$prefix" -v allowed=" $allowed_roots " '
  $0 != "" {
    path=$0
    if (path ~ /[\t\r]/ || path ~ /^\// || path ~ /(^|\/)\.\.($|\/)/ || path ~ /\/\//) {
      print "Unsafe managed archive path: " path > "/dev/stderr"; exit 1
    }
    root=path; sub("/.*", "", root)
    if (root !~ /^[A-Za-z0-9._+-]+$/) {
      print "Unsafe managed archive root: " root > "/dev/stderr"; exit 1
    }
    if (!index(allowed, " " root " ")) {
      print "Managed archive path has a disallowed root: " path > "/dev/stderr"; exit 1
    }
    paths[path]=1
    while (sub("/[^/]+$", "", path)) paths[path]=1
  }
  END { for (path in paths) printf "%s/%s%c", prefix, path, 0 }
' "$managed_paths_file" > "$inventory_dir/paths" || exit 1
case "$(uname -s)" in
  Darwin) stat_options=(-f $'%HT\t%N') ;;
  *) stat_options=(-c $'%F\t%n') ;;
esac
LC_ALL=C xargs -0 stat "${stat_options[@]}" < "$inventory_dir/paths" \
  > "$inventory_dir/existing" 2>/dev/null
stat_status=$?
# Missing files are expected. Other xargs failures (including a missing stat
# executable or a signal) must not turn into an empty successful inventory.
case "$stat_status" in 0|1|123) ;; *) exit 1 ;; esac
awk -F '\t' -v prefix="$prefix/" '
  FILENAME == ARGV[1] { managed[$0]=1; next }
  NF == 2 && index($2, prefix) == 1 {
    path=substr($2, length(prefix)+1)
    if ((path in managed) || tolower($1) == "symbolic link") print path
    next
  }
  { exit 1 }
' "$managed_paths_file" "$inventory_dir/existing" >> "$output" || exit 1

LC_ALL=C sort -u "$output" -o "$output" || exit 1
LC_ALL=C sort -u "$kegs_output" -o "$kegs_output" || exit 1
)

# Source: scripts/installer/extract.sh
php_darwin_extract() (


archive=${1:?}
prefix=${2:?}
exclude_file=${3:?}
archive_members=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-archive-members.XXXXXX") || exit 1
extract_members=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-extract-members.XXXXXX") || {
  rm -f "$archive_members"
  exit 1
}
permission_records=
extract_exclusions=
extract_inclusions=
stat_style=

path_uid() {
  case "$stat_style" in
    bsd) stat -f '%u' "$1" ;;
    gnu) stat -c '%u' "$1" ;;
  esac
}

path_gid() {
  case "$stat_style" in
    bsd) stat -f '%g' "$1" ;;
    gnu) stat -c '%g' "$1" ;;
  esac
}

path_mode() {
  case "$stat_style" in
    bsd) stat -f '%Lp' "$1" ;;
    gnu) stat -c '%a' "$1" ;;
  esac
}

restore_permissions() {
  local absolute_path
  local changed_owner
  local extra
  local gid
  local mode
  local relative_path
  local status=0
  local uid

  [ -n "$permission_records" ] && [ -s "$permission_records" ] || return 0
  while IFS=$'\t' read -r relative_path uid gid mode changed_owner extra; do
    [ -n "$relative_path" ] && [ -z "$extra" ] || {
      status=1
      continue
    }
    absolute_path="$prefix/$relative_path"
    if [ ! -d "$absolute_path" ] || [ -L "$absolute_path" ]; then
      printf 'Could not restore extraction directory: %s\n' "$relative_path" >&2
      status=1
      continue
    fi
    if ! chmod "$mode" "$absolute_path" 2>/dev/null && \
      ! sudo -n chmod "$mode" "$absolute_path"; then
      printf 'Could not restore extraction permissions: %s\n' "$relative_path" >&2
      status=1
    fi
    if [ "$changed_owner" = true ] && ! sudo -n chown "$uid:$gid" "$absolute_path"; then
      printf 'Could not restore extraction ownership: %s\n' "$relative_path" >&2
      status=1
    fi
  done < "$permission_records"
  [ "$status" -ne 0 ] || : > "$permission_records"
  return "$status"
}

# shellcheck disable=SC2329
cleanup() {
  local temporary_file

  trap '' HUP INT TERM
  restore_permissions || true
  for temporary_file in "$archive_members" "$extract_members" "$permission_records" \
    "$extract_exclusions" "$extract_inclusions"; do
    [ -z "$temporary_file" ] || rm -f "$temporary_file"
  done
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ -f "$archive" ] || {
  printf 'Archive not found: %s\n' "$archive" >&2
  exit 1
}
[ -d "$prefix" ] || {
  printf 'Extraction prefix not found: %s\n' "$prefix" >&2
  exit 1
}
[ -f "$exclude_file" ] || {
  printf 'Extraction exclusion list not found: %s\n' "$exclude_file" >&2
  exit 1
}
case "$(uname -s)" in
  Darwin) stat_style=bsd ;;
  *) stat_style=gnu ;;
esac

tar_version=$(tar --version) || exit 1
if [[ "$tar_version" == *bsdtar* ]] && [ -n "${4:-}" ] && [ -n "${5:-}" ]; then
  # The installer has authenticated the archive and validated its metadata.
  # Shared files are enumerated individually; kegs and the staged tap/PEAR tree
  # are whole subtrees. Existing kegs are excluded and replacement kegs have
  # been moved aside, so only these roots can have pre-existing parents.
  cat "$4" "$5" > "$archive_members" || exit 1
else
  tar --ignore-zeros -tf "$archive" > "$archive_members" || {
    printf 'Could not list archive members: %s\n' "$archive" >&2
    exit 1
  }
fi
extract_exclusions=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-exclusions.XXXXXX") || exit 1
extract_inclusions=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-inclusions.XXXXXX") || exit 1
# Collapse excluded members into the largest wholly excluded subtrees. Passing
# every included file to tar makes its pattern matcher quadratic on large kegs.
# Anchor and escape each exclusion so a prefix link never excludes a same-named
# library inside a newly installed keg.
awk -v exclusions="$extract_exclusions" -v inclusions="$extract_inclusions" '
  function parent(path) { sub("/[^/]+$", "", path); return path }
  function literal(path, result, i, c) {
    for (i=1; i<=length(path); i++) {
      c=substr(path, i, 1)
      if (index("\\[]*?$", c)) result=result "\\"
      result=result c
    }
    return result
  }
  FILENAME == ARGV[1] {
    if ($0 == "" || $0 ~ /[\t\r]/ || $0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ ||
        $0 ~ /(^|\/)\.($|\/)/ || $0 ~ /\/\// || $0 ~ /\/$/) exit 2
    excluded[$0]=1
    next
  }
  {
    path=$0
    if (path == "" || path ~ /[\t\r]/ || path ~ /^\// || path ~ /(^|\/)\.\.($|\/)/ ||
        path ~ /(^|\/)\.($|\/)/ || path ~ /\/\// || path ~ /\/$/) exit 3
    candidate=path
    while (1) {
      if (candidate in excluded) {
        omitted[path]=1
        while (index(path, "/")) { path=parent(path); omitted_parents[path]=1 }
        next
      }
      if (!sub("/[^/]+$", "", candidate)) break
    }
    print path
    included[path]=1
    retained[path]=1
    while (index(path, "/")) { path=parent(path); retained[path]=1 }
  }
  END {
    for (path in omitted) {
      while (index(path, "/") && !(parent(path) in retained)) path=parent(path)
      compact[path]=1
    }
    for (path in compact) print literal(path, "^") > exclusions
    for (path in included) {
      while (index(path, "/") && !(parent(path) in omitted_parents)) path=parent(path)
      compact_included[path]=1
    }
    for (path in compact_included) print literal(path, "") > inclusions
  }
' "$exclude_file" "$archive_members" > "$extract_members"
filter_status=$?
case "$filter_status" in
  0) ;;
  2) printf 'Unsafe extraction exclusion path\n' >&2; exit 1 ;;
  3) printf 'Unsafe archive member\n' >&2; exit 1 ;;
  *) printf 'Could not filter archive members\n' >&2; exit 1 ;;
esac
[ -s "$extract_members" ] || {
  printf 'Archive has no extractable members: %s\n' "$archive" >&2
  exit 1
}

permission_records=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-permissions.XXXXXX") || exit 1
awk '
  {
    path=$0
    while (sub("/[^/]+$", "", path)) print path
  }
' "$extract_members" | LC_ALL=C sort -u > "$archive_members" || exit 1
: > "$permission_records" || exit 1
current_uid=$(id -u) || exit 1
current_gid=$(id -g) || exit 1
while IFS= read -r relative_path; do
  absolute_path="$prefix/$relative_path"
  [ ! -L "$absolute_path" ] || {
    printf 'Extraction parent is a symlink: %s\n' "$relative_path" >&2
    exit 1
  }
  [ -d "$absolute_path" ] || continue
  [ ! -w "$absolute_path" ] || continue
  uid=$(path_uid "$absolute_path") || exit 1
  gid=$(path_gid "$absolute_path") || exit 1
  mode=$(path_mode "$absolute_path") || exit 1
  if [ "$uid" = "$current_uid" ]; then
    changed_owner=false
  else
    changed_owner=true
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$relative_path" "$uid" "$gid" "$mode" \
    "$changed_owner" >> "$permission_records" || exit 1
  if [ "$changed_owner" = true ]; then
    command -v sudo >/dev/null 2>&1 && \
      sudo -n chown "$current_uid:$current_gid" "$absolute_path" || exit 1
  fi
  chmod u+rwx "$absolute_path" || exit 1
  [ -w "$absolute_path" ] || exit 1
done < "$archive_members"

[ ! -s "$permission_records" ] || \
  printf 'Temporarily granting access to protected Homebrew directories\n'
case "$tar_version" in
  *bsdtar*)
    # libarchive scans its patterns for each member. Choose the smaller set of
    # complete subtrees, keeping both forms literal and rooted at the prefix.
    if [ "$(wc -l < "$extract_inclusions")" -lt "$(wc -l < "$extract_exclusions")" ]; then
      extract_options=(-T "$extract_inclusions")
    else
      extract_options=(-X "$extract_exclusions")
    fi
    ;;
  *) extract_options=(-T "$extract_members") ;;
esac
# Archive owner names can trigger slow OpenDirectory lookups on self-hosted
# Macs, even with --no-same-owner. Extraction still belongs to the current user.
tar --ignore-zeros -xkmpf "$archive" --no-same-owner --numeric-owner -C "$prefix" "${extract_options[@]}"
extract_status=$?
restore_permissions || exit 1
exit "$extract_status"
)

# Source: scripts/installer/install-state.sh
php_darwin_install_state() (


php_darwin_ruby - "$@" <<'PHP_DARWIN_INSTALL_STATE_RUBY'
begin
  mode, prefix, packages_file, selected_file, output_file, linked_file = ARGV
  packages = File.readlines(packages_file, chomp: true).map do |line|
    name, target, keg_only, extra = line.split("\t", -1)
    raise 'invalid package record' unless extra.nil? && %w[true false].include?(keg_only) &&
      name && !%w[. ..].include?(name) && name.match?(/\A[a-zA-Z0-9@+_.-]+\z/) &&
      target && target.match?(%r{\A\.\./Cellar/#{Regexp.escape(name)}/[^/\s]+\z}) &&
      !%w[. ..].include?(target.split('/').last)
    [name, target, keg_only]
  end
  selected = File.readlines(selected_file, chomp: true).each_with_object({}) { |name, set| set[name] = true }
  case mode
  when 'plan'
    existing_names = selected.keys.each_with_object({}) { |keg, set| set[keg.split('/')[1]] = true }
    changed, linked = [], []
    packages.each do |name, target, keg_only|
      next if selected.key?(target.delete_prefix('../'))
      changed << name
      next unless keg_only == 'false' && existing_names.key?(name)
      path = File.join(prefix, 'var/homebrew/linked', name)
      next unless File.symlink?(path)
      previous = File.readlink(path)
      raise "invalid linked dependency target for #{name}" unless previous.match?(%r{\A\.\./\.\./\.\./Cellar/#{Regexp.escape(name)}/[^/\s]+\z})
      linked << name
    end
    File.write(output_file, changed.map { |name| name + "\n" }.join)
    File.write(linked_file, linked.map { |name| name + "\n" }.join)
  when 'receipts'
    replacements = []
    packages.each do |name, target, _|
      raise "cache did not install #{target}" unless File.directory?(File.join(prefix, target.delete_prefix('../')))
      next unless selected.key?(name)
      path = File.join(prefix, 'opt', name)
      stat = begin
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      end
      raise "Homebrew opt path is not a symlink: #{path}" if stat && !stat.symlink?
      previous = stat && File.readlink(path)
      next if previous == target
      raise "invalid previous Homebrew opt link for #{name}" if previous && previous.match?(/[\r\n\t]/)
      replacements << [name, path, target, previous]
    end
    # Finish validation before mutation and journal each old target before
    # replacing it. The installer's existing rollback consumes this same file.
    File.open(output_file, 'a') do |journal|
      replacements.each do |name, path, target, previous|
        if previous
          journal.puts([name, previous].join("\t"))
          journal.flush
        end
        File.unlink(path) if previous
        File.symlink(target, path)
      end
    end
  else
    raise 'invalid installation state operation'
  end
rescue SystemCallError, RuntimeError, ArgumentError => error
  warn "php-darwin: installation state: #{error.message}"
  exit 1
end
PHP_DARWIN_INSTALL_STATE_RUBY
)

# Source: scripts/installer/verify-runtime.sh
php_darwin_verify_runtime() (

prefix=${1:?}
formula=${2:?}
expected_version=${3:?}
extensions=${4:?}
php_bin="$prefix/opt/$formula/bin/php"
php_config="$prefix/opt/$formula/bin/php-config"
[ -f "$php_bin" ] && [ -x "$php_bin" ] && [ ! -L "$php_bin" ] || {
  printf 'Cached PHP binary is missing or not executable\n' >&2
  exit 1
}
[ -f "$php_config" ] && [ ! -L "$php_config" ] || {
  printf 'Cached php-config is missing or is a symlink\n' >&2
  exit 1
}

# Read the same literal assignment used by setup-php's php_semver. Never source
# php-config or start PHP to read a version already authenticated by the cache.
installed_version=
while IFS= read -r config_line; do
  case "$config_line" in
    version=\"*\")
      [ -z "$installed_version" ] || { printf 'Duplicate php-config version\n' >&2; exit 1; }
      installed_version=${config_line#version=\"}
      installed_version=${installed_version%\"}
      ;;
  esac
done < "$php_config"
[ "$installed_version" = "$expected_version" ] || {
  printf 'Cached php-config version mismatch: expected %s, found %s\n' \
    "$expected_version" "$installed_version" >&2
  exit 1
}
while IFS=$'\t' read -r extension extension_type extension_path extra; do
  [[ "$extension" =~ ^[A-Za-z0-9_]+$ ]] && [ -z "$extra" ] && \
    [[ "$extension_type" =~ ^(extension|zend_extension)$ ]] && \
    [[ "$extension_path" =~ ^(Cellar|lib)/ ]] && \
    [[ ! "$extension_path" =~ (^|/)\.\.(/|$) ]] || exit 1
  [ -s "$prefix/$extension_path" ] && [ ! -L "$prefix/$extension_path" ] || {
    printf 'Cached %s module is missing or is a symlink\n' "$extension" >&2
    exit 1
  }
done < "$extensions"

# Reused Homebrew kegs may have broken loader paths even when their version
# and receipt look correct. One process checks those paths without recompiling
# dependencies or using PHP for version discovery.
"$php_bin" -n -r 'exit(0);' || {
  printf 'Cached PHP runtime smoke test failed; check the reused dependency paths\n' >&2
  exit 1
}

# Release QA tests each extension before publication. Keep the more expensive
# per-extension probes available for explicit installation diagnostics.
if [ "${PHP_DARWIN_VERIFY_RUNTIME:-false}" = true ]; then
  while IFS=$'\t' read -r extension extension_type extension_path; do
    "$php_bin" -n -d "$extension_type=$prefix/$extension_path" -r \
      "if (!extension_loaded('$extension')) { exit(1); }" || {
      printf 'Cached %s module does not load\n' "$extension" >&2
      exit 1
    }
  done < "$extensions"
fi
)

# Source: scripts/installer/install-package.sh



PHP_DARWIN_PHASE=input
version=${1:-}
build=${2:-release}
ts=${3:-nts}
local_archive=${4:-}
# setup-php exports its action input to child processes. Older action revisions
# call this installer with three arguments; use that input on the cold path too.
extensions_input=${5-${PHP_DARWIN_EXTENSIONS:-${INPUT_EXTENSIONS:-}}}
arch=$(php_darwin_normalize_arch "$(uname -m)") || exit 1

PHP_DARWIN_PHASE=environment
[ "$(uname -s)" = Darwin ] || php_darwin_die 'the cache installer only supports macOS'
for required_command in brew curl jq tar zstd; do
  command -v "$required_command" >/dev/null 2>&1 || php_darwin_die "$required_command is required"
done

install_config=$(jq -ers --arg arch "$arch" '
  def install_string: type == "string" and length > 0 and test("^[^\\r\\n\\t]+$");
  .[0] as $package | .[1][$arch] as $platform |
  select(($package.current_version | install_string) and
    ($package.release_repository | install_string) and
    ($package.tap | install_string) and
    ($package.tap_repository | install_string) and
    ($package.tap_branch | install_string) and
    ($package.tap_snapshot | install_string) and
    ($platform.brew_prefix | install_string) and
    ($platform.minimum_macos | type == "number" and floor == . and . > 0) and
    ($platform.platform_key | install_string)) |
  [$package.current_version, $package.release_repository, $package.tap,
   $package.tap_repository, $package.tap_branch, $package.tap_snapshot,
   $platform.brew_prefix, ($platform.minimum_macos | tostring), $platform.platform_key] | @tsv
' < <(php_darwin_read_config package.json; php_darwin_read_config platforms.json)) || \
  php_darwin_die 'could not read the package and platform configuration'
IFS=$'\t' read -r current_version package_release_repository tap tap_repository tap_branch \
  tap_snapshot expected_prefix minimum_macos platform_key install_config_extra <<< "$install_config" || \
  php_darwin_die 'could not parse the package and platform configuration'
[ -z "$install_config_extra" ] && [ -n "$platform_key" ] || \
  php_darwin_die 'package and platform configuration fields are invalid'
[ -n "$version" ] || version=$current_version
php_darwin_validate_version "$version"
channel=$(php_darwin_version_channel "$version") || exit 1
php_darwin_validate_build "$build"
php_darwin_validate_ts "$ts"
requested_formula=$(php_darwin_requested_formula "$version" "$build" "$ts") || exit 1
formula=$(php_darwin_formula "$version" "$build" "$ts" "$current_version") || exit 1
config_id=$(php_darwin_config_id "$version" "$build" "$ts") || exit 1
asset=$(php_darwin_asset "$version" "$build" "$ts" "$arch") || exit 1
pear_path=$(php_darwin_pear_path "$version" "$formula") || exit 1
internal_metadata_path=$(php_darwin_metadata_path "$asset") || exit 1

brew_command=$(command -v brew)
if [ "$brew_command" = "$expected_prefix/bin/brew" ]; then
  brew_prefix=$expected_prefix
else
  brew_prefix=$(brew --prefix) || php_darwin_die 'could not determine the Homebrew prefix'
fi
[ "$brew_prefix" = "$expected_prefix" ] || php_darwin_die "architecture $arch requires Homebrew at $expected_prefix, found $brew_prefix"
internal_metadata_dir="$brew_prefix/${internal_metadata_path%/*}"
macos_version=$(sw_vers -productVersion) || php_darwin_die 'could not determine the macOS version'
macos_major=${macos_version%%.*}
case "$tap_snapshot" in var/php-darwin/*) ;; *)
  php_darwin_die "unsafe Homebrew tap snapshot path: $tap_snapshot"
  ;;
esac
case "$tap_snapshot" in *$'\n'*|*$'\r'*|*$'\t'*|*'/../'*|../*|*/..|*'//'* )
  php_darwin_die "unsafe Homebrew tap snapshot path: $tap_snapshot"
  ;;
esac

[ ! -L "$internal_metadata_dir" ] || php_darwin_die 'embedded metadata directory is a symlink'
[ ! -e "$internal_metadata_dir" ] || [ -d "$internal_metadata_dir" ] || \
  php_darwin_die 'embedded metadata path is not a directory'
mkdir -p "$internal_metadata_dir" || php_darwin_die 'could not create the embedded metadata directory'

while IFS= read -r managed_dir extra; do
  [ -n "$managed_dir" ] || continue
  case "$managed_dir" in \#*) continue ;; esac
  [ -z "$extra" ] || php_darwin_die "invalid archive root: $managed_dir $extra"
  case "$managed_dir" in Cellar|Frameworks|bin|etc|include|lib|opt|sbin|share|var) ;; *)
    php_darwin_die "unsafe archive root: $managed_dir"
    ;;
  esac
  [ ! -L "$brew_prefix/$managed_dir" ] || \
    php_darwin_die "Homebrew directory is a symlink: $brew_prefix/$managed_dir"
  [ -d "$brew_prefix/$managed_dir" ] || mkdir -p "$brew_prefix/$managed_dir" || \
    php_darwin_die "could not create Homebrew directory: $brew_prefix/$managed_dir"
  [ -w "$brew_prefix/$managed_dir" ] || \
    php_darwin_die "Homebrew directory is not writable: $brew_prefix/$managed_dir"
done < <(php_darwin_read_config archive-paths)

php_darwin_configure_homebrew_environment

tmp_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-install.XXXXXX") || \
  php_darwin_die 'could not create the installation directory'
php_darwin_select_ruby
archive_roots_file="$tmp_dir/archive-paths.txt"
php_darwin_read_config archive-paths > "$archive_roots_file" || \
  php_darwin_die 'could not stage the archive root configuration'
tap_log="$tmp_dir/homebrew-tap.log"
tap_pid=
tap_action_file="$tmp_dir/homebrew-tap-action.txt"
homebrew_prepare_log="$tmp_dir/homebrew-prepare.log"
homebrew_prepare_pid=
homebrew_trust_pid=
homebrew_trust_log="$tmp_dir/homebrew-trust.log"
homebrew_prepare_phase_file="$tmp_dir/homebrew-prepare-phase.txt"
php_unlink_mode_file="$tmp_dir/php-unlink-mode"
dependency_unlink_mode_file="$tmp_dir/dependency-unlink-mode"
unlink_journal_dir="$tmp_dir/unlinked"
command_links_journal="$tmp_dir/php-command-links.json"
tap_path_file="$tmp_dir/homebrew-tap-path.txt"
tap_trust_file="$tmp_dir/homebrew-tap-trust.txt"
initial_formula_trust_file="$tmp_dir/homebrew-formula-trust.txt"
missing_log="$tmp_dir/homebrew-missing.log"
missing_pid=
missing_status=
missing_output=
archive_hash_file="$tmp_dir/archive.sha256"
archive_hash_log="$tmp_dir/archive-hash.log"
archive_hash_pid=
linked_php_references=()
linked_dependency_references=()
postinstall_paths_file="$tmp_dir/postinstall-paths.txt"
postinstall_candidates_file="$tmp_dir/postinstall-candidates.txt"
postinstall_backup_dir="$tmp_dir/postinstall-backup"
postinstall_restored_file="$tmp_dir/postinstall-restored.txt"
pear_backup="$tmp_dir/pear-backup"
pear_backed_up=false
pear_restored=false
previous_opt_links="$tmp_dir/previous-opt-links.tsv"
new_state_paths_file="$tmp_dir/new-state-paths.txt"
target_keg_backup="$tmp_dir/target-keg-backup"
target_keg_backed_up=false
formula_trust_marker="$tmp_dir/formula-trust-added"
formula_trust_pending="$tmp_dir/formula-trust-pending"
tap_was_trusted=false
tap_installed=false
tap_path=
tap_path_backup=
tap_path_backed_up=false
tap_snapshot_backup="$tmp_dir/homebrew-tap-snapshot-backup"
tap_snapshot_backed_up=false
tap_snapshot_extracted=false
tap_replaced=false
tap_restore_after_install=false
dependencies_started_with_pending_tap=false
tap_snapshot_path="$brew_prefix/$tap_snapshot"
: > "$previous_opt_links" || php_darwin_die 'could not create the Homebrew opt-link backup'
: > "$postinstall_restored_file" || php_darwin_die 'could not create the restored-state list'
: > "$new_state_paths_file" || php_darwin_die 'could not create the new-state list'
archive_mutation_started=false
runtime_verified=false
extension_prefetch_pid=
extension_node=
extension_dir="$tmp_dir/extensions"
preserve_tmp_dir=false
php_darwin_unlink_formulae() {
  local mode_file=$1
  local unlink_status=0
  shift

  printf 'fast\n' > "$mode_file" || return 1
  php_darwin_unlink_kegs unlink "$brew_prefix" "$unlink_journal_dir" "$@" || unlink_status=$?
  if [ "$unlink_status" -eq 78 ]; then
    printf 'brew\n' > "$mode_file" || return 1
    brew unlink "$@"
  else
    return "$unlink_status"
  fi
}

php_darwin_check_installed_dependencies() {
  local dependency_status=0

  php_darwin_check_dependencies "$brew_prefix" "$packages_file" || dependency_status=$?
  if [ "$dependency_status" -eq 78 ]; then
    brew missing "$tap/$formula"
  else
    return "$dependency_status"
  fi
}

php_darwin_collect_dependencies() {
  [ -n "$missing_pid" ] || return 0
  if wait "$missing_pid"; then
    missing_status=0
  else
    missing_status=$?
  fi
  missing_pid=
  missing_output=$(cat "$missing_log") || php_darwin_die 'could not read Homebrew dependency diagnostics'
}

php_darwin_validate_dependencies() {
  [ -n "$missing_status" ] || return 0
  [ "$missing_status" -eq 0 ] || [ -n "$missing_output" ] || \
    php_darwin_die 'Homebrew dependency validation failed without diagnostics'
  if [ -n "$missing_output" ]; then
    php_darwin_die "cache has missing Homebrew dependencies: $missing_output"
  fi
  missing_status=
  missing_output=
}

php_darwin_wait_for_dependencies() {
  php_darwin_collect_dependencies
  php_darwin_validate_dependencies
}

php_darwin_resolve_tap_and_dependencies() {
  if [ -n "$tap_pid" ]; then
    # Do not replace the tap while Homebrew is reading the outgoing formula.
    # Its result is authoritative only if that tap remains installed.
    php_darwin_collect_dependencies
    php_darwin_wait_for_tap
    if [ "$tap_replaced" = true ] && [ "$dependencies_started_with_pending_tap" = true ]; then
      missing_status=
      missing_output=
      PHP_DARWIN_PHASE=homebrew.dependencies
      php_darwin_check_installed_dependencies > "$missing_log" 2>&1 &
      missing_pid=$!
    fi
  else
    php_darwin_wait_for_tap
  fi
  PHP_DARWIN_PHASE=homebrew.dependencies
  php_darwin_wait_for_dependencies
}

php_darwin_wait_for_tap() {
  local tap_action
  local tap_status

  [ -n "$tap_pid" ] || return 0
  if wait "$tap_pid"; then
    tap_status=0
  else
    tap_status=$?
  fi
  tap_pid=
  if [ "$tap_status" -ne 0 ]; then
    PHP_DARWIN_PHASE=homebrew.tap
    cat "$tap_log" >&2
    php_darwin_die "could not validate $tap"
  fi
  PHP_DARWIN_PHASE=homebrew.tap
  tap_action=$(cat "$tap_action_file") || php_darwin_die "could not read the $tap tap action"
  case "$tap_action" in
    keep)
      find "$tap_snapshot_path" -mindepth 1 -delete || \
        php_darwin_die 'could not remove the unused Homebrew tap snapshot'
      rmdir "$tap_snapshot_path" || php_darwin_die 'could not remove the empty Homebrew tap snapshot'
      tap_snapshot_extracted=false
      ;;
    replace|temporary)
      [ "$tap_action" != temporary ] || tap_restore_after_install=true
      tap_path_backed_up=true
      if ! mv "$tap_path" "$tap_path_backup" 2>/dev/null; then
        command -v sudo >/dev/null 2>&1 || \
          php_darwin_die "could not back up the older $tap snapshot"
        sudo -n mv "$tap_path" "$tap_path_backup" || \
          php_darwin_die "could not back up the older $tap snapshot"
      fi
      tap_installed=true
      if ! mv "$tap_snapshot_path" "$tap_path" 2>/dev/null; then
        command -v sudo >/dev/null 2>&1 || \
          php_darwin_die "could not install the cached $tap snapshot"
        sudo -n mv "$tap_snapshot_path" "$tap_path" || \
          php_darwin_die "could not install the cached $tap snapshot"
      fi
      tap_snapshot_extracted=false
      tap_replaced=true
      ;;
    *) php_darwin_die "invalid $tap tap action: $tap_action" ;;
  esac
}

php_darwin_wait_for_homebrew_prepare() {
  local failed_phase
  local prepare_status

  [ -n "$homebrew_prepare_pid" ] || return 0
  if wait "$homebrew_prepare_pid"; then
    prepare_status=0
  else
    prepare_status=$?
  fi
  homebrew_prepare_pid=
  if [ "$prepare_status" -ne 0 ]; then
    failed_phase=$(cat "$homebrew_prepare_phase_file" 2>/dev/null) || \
      failed_phase=homebrew.prepare
    case "$failed_phase" in
      homebrew.trust-state|homebrew.tap-path|homebrew.unlink) ;;
      *) failed_phase=homebrew.prepare ;;
    esac
    PHP_DARWIN_PHASE="$failed_phase"
    cat "$homebrew_prepare_log" >&2
    case "$failed_phase" in
      homebrew.trust-state) php_darwin_die "could not read the $tap trust state" ;;
      homebrew.tap-path) php_darwin_die "could not resolve the $tap repository path" ;;
      homebrew.unlink) php_darwin_die 'could not unlink the active Homebrew PHP formulae' ;;
      *) php_darwin_die 'could not prepare Homebrew for cache installation' ;;
    esac
  fi
  if ! wait "$homebrew_trust_pid"; then
    homebrew_trust_pid=
    PHP_DARWIN_PHASE=homebrew.trust-state
    cat "$homebrew_trust_log" >&2
    php_darwin_die "could not read the $tap trust state"
  fi
  homebrew_trust_pid=
  tap_path=$(cat "$tap_path_file") || php_darwin_die "could not read the $tap repository path"
  tap_was_trusted=$(cat "$tap_trust_file") || \
    php_darwin_die "could not read the $tap trust state"
  case "$tap_was_trusted" in true|false) ;; *) php_darwin_die "invalid $tap trust state" ;; esac
}

php_darwin_start_archive_hash() {
  local archive_to_hash=$1

  (
    php_darwin_sha256 "$archive_to_hash" > "$archive_hash_file"
  ) > "$archive_hash_log" 2>&1 &
  archive_hash_pid=$!
}

php_darwin_wait_for_archive_hash() {
  local hash_status

  [ -n "$archive_hash_pid" ] || return 0
  if wait "$archive_hash_pid"; then
    hash_status=0
  else
    hash_status=$?
  fi
  archive_hash_pid=
  if [ "$hash_status" -ne 0 ]; then
    cat "$archive_hash_log" >&2
    php_darwin_die "could not hash $asset"
  fi
  actual_hash=$(cat "$archive_hash_file") || php_darwin_die "could not read the $asset hash"
}

php_darwin_restore_formula_trust() {
  local added_formula
  local added_formulae=()
  local trust_entries_file
  local trust_restore_status

  [ -f "$formula_trust_marker" ] || [ -f "$formula_trust_pending" ] || return 0
  trust_entries_file=$formula_trust_marker
  [ -f "$trust_entries_file" ] || trust_entries_file=$formula_trust_pending
  while IFS= read -r added_formula; do
    case "$added_formula" in "$tap/"*) added_formulae+=("$added_formula") ;; *) return 1 ;; esac
  done < "$trust_entries_file"
  if [ "${#added_formulae[@]}" -eq 0 ]; then
    rm -f "$formula_trust_marker" "$formula_trust_pending"
    return 0
  fi
  # Homebrew's untrust command is idempotent. The marker contains only
  # formulae absent from the initial trust snapshot, so querying trust again
  # after archive extraction is unnecessary and would depend on the mutated
  # Homebrew prefix during rollback.
  trust_restore_status=0
  php_darwin_trust_store remove "$brew_prefix" "$tap" '' "${added_formulae[@]}" || trust_restore_status=$?
  if [ "$trust_restore_status" -eq 78 ]; then
    trust_restore_status=0
    brew untrust --formula "${added_formulae[@]}" || trust_restore_status=$?
  fi
  [ "$trust_restore_status" -eq 0 ] || {
    printf 'Run brew untrust --formula %s to remove trust added by the failed cache install\n' \
      "${added_formulae[*]}" >&2
    return 1
  }
  rm -f "$formula_trust_marker" "$formula_trust_pending"
}

php_darwin_install_cleanup() {
  cleanup_status=$?
  PHP_DARWIN_PHASE=cleanup
  rollback_status=ok
  rollback_attempted=false
  rollback_log="$tmp_dir/rollback.log"
  trap - EXIT
  trap '' HUP INT TERM
  : > "$rollback_log"
  # Give the potentially mutating Homebrew preparation a bounded opportunity
  # to finish. Read-only validation jobs can be stopped immediately.
  php_darwin_reap_job "$homebrew_prepare_pid" 20
  php_darwin_reap_job "$homebrew_trust_pid" 0
  php_darwin_reap_job "$tap_pid" 0
  php_darwin_reap_job "$missing_pid" 0
  php_darwin_reap_job "$archive_hash_pid" 0
  # The Node supervisor drains its read-only extraction children on termination.
  php_darwin_reap_job "$extension_prefetch_pid" 5
  if [ "$cleanup_status" -ne 0 ] && [ "$runtime_verified" = false ]; then
    rollback_attempted=true
    if [ "$tap_installed" = true ]; then
      if [ ! -e "$tap_path" ] && [ ! -L "$tap_path" ]; then
        :
      elif [ -d "$tap_path" ] && [ ! -L "$tap_path" ]; then
        php_darwin_remove_tap_path "$brew_prefix" "$tap_path" >> "$rollback_log" 2>&1 || \
          rollback_status=failed
      else
        rollback_status=failed
      fi
    fi
    if [ "$tap_path_backed_up" = true ]; then
      if [ ! -e "$tap_path_backup" ] && [ ! -L "$tap_path_backup" ] && \
        { [ -e "$tap_path" ] || [ -L "$tap_path" ]; }; then
        tap_path_backed_up=false
      elif php_darwin_restore_tap_path "$tap_path" "$tap_path_backup" >> "$rollback_log" 2>&1; then
        tap_path_backed_up=false
      else
        rollback_status=failed
      fi
    fi
    if [ "$tap_snapshot_extracted" = true ] && \
      { [ -e "$tap_snapshot_path" ] || [ -L "$tap_snapshot_path" ]; }; then
      if [ -d "$tap_snapshot_path" ] && [ ! -L "$tap_snapshot_path" ]; then
        find "$tap_snapshot_path" -mindepth 1 -delete >> "$rollback_log" 2>&1 && \
          rmdir "$tap_snapshot_path" >> "$rollback_log" 2>&1 || rollback_status=failed
      else
        rollback_status=failed
      fi
    fi
    if [ "$tap_snapshot_backed_up" = true ] && [ -d "$tap_snapshot_backup" ]; then
      mkdir -p "${tap_snapshot_path%/*}" >> "$rollback_log" 2>&1 && \
        mv "$tap_snapshot_backup" "$tap_snapshot_path" >> "$rollback_log" 2>&1 || rollback_status=failed
    fi
    if [ -s "${changed_formulae_file:-}" ]; then
      if [ -s "${installed_links_file:-}" ]; then
        while IFS=$'\t' read -r rollback_link rollback_target; do
          rollback_owned=false
          while IFS= read -r rollback_formula; do
            case "$rollback_target" in *"Cellar/$rollback_formula/"*) rollback_owned=true; break ;; esac
          done < "$changed_formulae_file"
          if [ "$rollback_owned" = true ] && [ -L "$brew_prefix/$rollback_link" ] && \
            [ "$(readlink "$brew_prefix/$rollback_link")" = "$rollback_target" ]; then
            rm -f "$brew_prefix/$rollback_link" >> "$rollback_log" 2>&1 || rollback_status=failed
          fi
        done < "$installed_links_file"
      fi
      if [ -s "${packages_file:-}" ]; then
        while IFS=$'\t' read -r rollback_formula rollback_opt_target rollback_keg_only; do
          case "$rollback_keg_only" in true|false) ;; *) rollback_status=failed; continue ;; esac
          grep -Fxq "$rollback_formula" "$changed_formulae_file" || continue
          rollback_opt="$brew_prefix/opt/$rollback_formula"
          if [ -L "$rollback_opt" ] && [ "$(readlink "$rollback_opt")" = "$rollback_opt_target" ]; then
            rm -f "$rollback_opt" >> "$rollback_log" 2>&1 || rollback_status=failed
          fi
          rollback_keg=${rollback_opt_target#../}
          case "$rollback_keg" in "Cellar/$rollback_formula/"*)
            rm -rf "${brew_prefix:?}/${rollback_keg:?}" >> "$rollback_log" 2>&1 || rollback_status=failed
            # Extraction may have created the rack. Remove it only when empty;
            # an older side-by-side keg keeps the directory in place.
            rmdir "$brew_prefix/Cellar/$rollback_formula" >> "$rollback_log" 2>&1 || true
            ;;
          esac
        done < "$packages_file"
      fi
      while IFS=$'\t' read -r rollback_formula rollback_opt_target; do
        rollback_opt="$brew_prefix/opt/$rollback_formula"
        if [ -e "$rollback_opt" ] && [ ! -L "$rollback_opt" ]; then
          rollback_status=failed
          continue
        fi
        if [ ! -L "$rollback_opt" ] || [ "$(readlink "$rollback_opt")" != "$rollback_opt_target" ]; then
          rm -f "$rollback_opt" >> "$rollback_log" 2>&1 && \
            ln -s "$rollback_opt_target" "$rollback_opt" >> "$rollback_log" 2>&1 || rollback_status=failed
        fi
      done < "$previous_opt_links"
    fi
    if [ "$target_keg_backed_up" = true ]; then
      if [ -e "$brew_prefix/$target_keg_relative" ] || [ -L "$brew_prefix/$target_keg_relative" ]; then
        rm -rf "${brew_prefix:?}/${target_keg_relative:?}" >> "$rollback_log" 2>&1 || \
          rollback_status=failed
      fi
      mkdir -p "$brew_prefix/${target_keg_relative%/*}" >> "$rollback_log" 2>&1 && \
        mv "$target_keg_backup" "$brew_prefix/$target_keg_relative" >> "$rollback_log" 2>&1 || \
        rollback_status=failed
      target_keg_backed_up=false
    fi
    if [ "$archive_mutation_started" = true ] && [ -s "$new_state_paths_file" ]; then
      while IFS= read -r rollback_state_path; do
        [ -n "$rollback_state_path" ] || continue
        rm -rf "${brew_prefix:?}/${rollback_state_path:?}" >> "$rollback_log" 2>&1 || \
          rollback_status=failed
      done < "$new_state_paths_file"
    fi
    if [ "$pear_backed_up" = true ]; then
      rm -rf "${brew_prefix:?}/${pear_path:?}" >> "$rollback_log" 2>&1 || rollback_status=failed
      mkdir -p "$brew_prefix/${pear_path%/*}" >> "$rollback_log" 2>&1 && \
        mv "$pear_backup" "$brew_prefix/$pear_path" >> "$rollback_log" 2>&1 || rollback_status=failed
      pear_backed_up=false
    elif [ "$archive_mutation_started" = true ] && [ "$pear_restored" = false ]; then
      rm -rf "${brew_prefix:?}/${pear_path:?}" >> "$rollback_log" 2>&1 || rollback_status=failed
    fi
    if [ -s "$postinstall_paths_file" ]; then
      while IFS= read -r postinstall_path; do
        [ -n "$postinstall_path" ] || continue
        if [ -e "$postinstall_backup_dir/$postinstall_path" ] || \
          [ -L "$postinstall_backup_dir/$postinstall_path" ]; then
          rm -rf "${brew_prefix:?}/${postinstall_path:?}" >> "$rollback_log" 2>&1 || rollback_status=failed
          mkdir -p "$brew_prefix/${postinstall_path%/*}" >> "$rollback_log" 2>&1 && \
            mv "$postinstall_backup_dir/$postinstall_path" "$brew_prefix/$postinstall_path" \
              >> "$rollback_log" 2>&1 || rollback_status=failed
        elif grep -Fxq "$postinstall_path" "$postinstall_restored_file"; then
          continue
        elif [ "$archive_mutation_started" = true ]; then
          rm -rf "${brew_prefix:?}/${postinstall_path:?}" >> "$rollback_log" 2>&1 || rollback_status=failed
        fi
      done < "$postinstall_paths_file"
    fi
    if [ "$archive_mutation_started" = true ]; then
      rm -f "$brew_prefix/$internal_metadata_path" >> "$rollback_log" 2>&1 || rollback_status=failed
    fi
    php_darwin_php_command_links restore "$brew_prefix" "$command_links_journal" >> "$rollback_log" 2>&1 || \
      rollback_status=failed
    if [ -d "$unlink_journal_dir" ]; then
      php_darwin_unlink_kegs restore "$brew_prefix" "$unlink_journal_dir" >> "$rollback_log" 2>&1 || \
        rollback_status=failed
    fi
    if [ "${#linked_php_references[@]}" -gt 0 ] && [ "$(cat "$php_unlink_mode_file" 2>/dev/null)" = brew ]; then
      brew link --overwrite --force "${linked_php_references[@]}" >> "$rollback_log" 2>&1 || \
        rollback_status=failed
    fi
    if [ "${#linked_dependency_references[@]}" -gt 0 ] && [ "$(cat "$dependency_unlink_mode_file" 2>/dev/null)" = brew ]; then
      brew link --overwrite "${linked_dependency_references[@]}" >> "$rollback_log" 2>&1 || \
        rollback_status=failed
    fi
    php_darwin_restore_formula_trust >> "$rollback_log" 2>&1 || rollback_status=failed
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    if [ "$rollback_attempted" = false ]; then
      printf 'php-darwin: verified installation preserved after post-install interruption\n' >&2
    elif [ "$rollback_status" = failed ]; then
      printf 'php-darwin: rollback failed; Homebrew diagnostics follow\n' >&2
      cat "$rollback_log" >&2
    fi
    [ "$rollback_attempted" = false ] || printf 'php-darwin: rollback %s\n' "$rollback_status" >&2
  fi
  if [ "$runtime_verified" = true ] && [ "$tap_snapshot_backed_up" = true ]; then
    preserve_tmp_dir=true
    printf 'php-darwin: restore the previous cache tap with: sudo mv %s %s\n' \
      "$tap_snapshot_backup" "$tap_snapshot_path" >&2
  fi
  # A failed restore must never discard the only remaining copies of user
  # state. Keep the entire transaction, including journals and diagnostics.
  if [ "$rollback_status" = failed ]; then
    preserve_tmp_dir=true
  fi
  if [ "$preserve_tmp_dir" = true ]; then
    printf 'php-darwin: preserved recovery files in %s\n' "$tmp_dir" >&2
  else
    rm -rf "$tmp_dir"
  fi
  exit "$cleanup_status"
}
trap php_darwin_install_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Optional pack preparation is read-only and overlaps the base PHP install.
# Node is optional: PHP-only installs and unavailable pack support keep working.
if [ -n "$extensions_input" ] && extension_node=$(command -v "${PHP_DARWIN_NODE:-node}"); then
  mkdir -p "$extension_dir" &&
    php_darwin_extension_installer > "$extension_dir/install-extensions.cjs" &&
    "$extension_node" "$extension_dir/install-extensions.cjs" select "$extension_dir" "$extensions_input" &&
    if [ -s "$extension_dir/requested.txt" ]; then
      "$extension_node" "$extension_dir/install-extensions.cjs" prefetch-requested "$extension_dir" \
        "$version" "$build" "$ts" "$arch" > "$extension_dir/prefetch.log" 2>&1 &
      extension_prefetch_pid=$!
    fi
fi

# Reading Homebrew trust, unlinking PHP, and downloading the cache are
# independent. Track the read-only and mutating workers separately so cleanup
# can stop trust queries while safely completing or rolling back unlinking.
for linked_php_path in "$brew_prefix/var/homebrew/linked"/php*; do
  [ -L "$linked_php_path" ] || continue
  linked_php_formula=${linked_php_path##*/}
  php_darwin_is_php_formula "$linked_php_formula" || continue
  linked_php_target=$(readlink "$linked_php_path") || \
    php_darwin_die "could not read the linked Homebrew formula $linked_php_formula"
  case "$linked_php_target" in "../../../Cellar/$linked_php_formula/"*) ;; *)
    php_darwin_die "invalid linked Homebrew formula target: $linked_php_target"
    ;;
  esac
  linked_php_reference=$(php_darwin_keg_formula_reference "$brew_prefix" "$linked_php_formula" \
    "${linked_php_target#../../../}" "$tap") || \
    php_darwin_die "could not resolve the installed Homebrew formula $linked_php_formula"
  # Unlink the validated installed rack. A qualified tap name asks Homebrew
  # to load the formula again and fails when its original tap was untapped.
  # The same bare name also lets native rollback relink that installed keg.
  linked_php_references+=("${linked_php_reference##*/}")
done
: > "$homebrew_prepare_phase_file" || php_darwin_die 'could not create the Homebrew preparation phase file'
(
  trust_status=0
  trust_json=$(php_darwin_trust_store snapshot "$brew_prefix") || trust_status=$?
  if [ "$trust_status" -eq 78 ]; then
    trust_json=$(brew trust --json=v1) || exit 1
  elif [ "$trust_status" -ne 0 ]; then
    exit "$trust_status"
  fi
  if php_darwin_tap_trusted "$tap" "$trust_json"; then
    printf 'true\n' > "$tap_trust_file" || exit 1
  else
    trust_status=$?
    [ "$trust_status" -eq 1 ] || exit 1
    printf 'false\n' > "$tap_trust_file" || exit 1
  fi
  # Reuse the combined snapshot. Older Homebrew revisions pluralized this key
  # differently; an unknown schema can still use the selected collection.
  formula_trust_json=$(jq -c '
    if has("formulae") then .formulae elif has("formulas") then .formulas else empty end
  ' <<< "$trust_json") || exit 1
  [ -n "$formula_trust_json" ] || \
    formula_trust_json=$(brew trust --formula --json=v1) || exit 1
  jq -r '
    if type == "array" and all(.[]; type == "string") then .[]
    else error("invalid Homebrew formula trust response")
    end
  ' <<< "$formula_trust_json" > "$initial_formula_trust_file" || exit 1
) > "$homebrew_trust_log" 2>&1 &
homebrew_trust_pid=$!
(
  printf 'homebrew.tap-path\n' > "$homebrew_prepare_phase_file" || exit 1
  php_darwin_tap_repository_path "$tap" > "$tap_path_file" || exit 1
  if [ "${#linked_php_references[@]}" -gt 0 ]; then
    printf 'homebrew.unlink\n' > "$homebrew_prepare_phase_file" || exit 1
    php_darwin_unlink_formulae "$php_unlink_mode_file" "${linked_php_references[@]}" || exit 1
  fi
) > "$homebrew_prepare_log" 2>&1 &
homebrew_prepare_pid=$!

archive="$tmp_dir/$asset"
external_metadata=
cached_source_hash=
manifest_homebrew_commit=
manifest_php_src_commit=
manifest_php_semver=
manifest_source_hash=
manifest_download_asset=
manifest_archive_bytes=
manifest_extensions_commit=
manifest_from_embedded=false
release_archive_error=

php_darwin_use_release_manifest() {
  local manifest_file=$1
  local manifest_values

  manifest_values=$(php_darwin_validate_release_manifest \
    "$manifest_file" "$version" "$channel" "$asset") || return 1
  IFS=$'\t' read -r expected_hash manifest_homebrew_commit manifest_php_src_commit \
    manifest_php_semver manifest_source_hash manifest_download_asset manifest_extensions_commit \
    <<< "$manifest_values" || return 1
  [ -n "$expected_hash" ] && [ -n "$manifest_homebrew_commit" ] && \
    [ -n "$manifest_php_src_commit" ] && [ -n "$manifest_php_semver" ] && \
    [ -n "$manifest_source_hash" ] && [ -n "$manifest_download_asset" ] && \
    [ -n "$manifest_extensions_commit" ] || return 1
  [ "$manifest_php_src_commit" != - ] || manifest_php_src_commit=
  [ "$manifest_extensions_commit" != - ] || manifest_extensions_commit=
  manifest_archive_bytes=$(jq -er --arg asset "$asset" \
    '.assets[] | select(.name == $asset) | .bytes' "$manifest_file") || return 1
}

php_darwin_refresh_release_manifest() {
  manifest_url=${PHP_DARWIN_MANIFEST_URL:-}
  [ -n "$manifest_url" ] || manifest_url=$(php_darwin_release_manifest_url "$release_repository" "$version") || \
    php_darwin_die 'could not construct the release manifest URL'
  manifest_status=$(php_darwin_fetch_release_manifest "$release_repository" "$version" \
    "$release_manifest" "${PHP_DARWIN_MANIFEST_URL:-}") || php_darwin_die "could not request $manifest_url"
  [ "$manifest_status" = 200 ] || \
    php_darwin_die "could not fetch the PHP $version release manifest (HTTP $manifest_status)"
  php_darwin_use_release_manifest "$release_manifest" || \
    php_darwin_die 'release manifest did not match the requested PHP version'
  manifest_from_embedded=false
}

php_darwin_download_release_archive() {
  local archive_http_status
  local mirror_url
  local urls=()
  local destination
  local resume_bytes='' request_result received_bytes

  release_archive_error=
  release_url=${PHP_DARWIN_RELEASE_URL:-https://github.com/$release_repository/releases/download/php-$version/$manifest_download_asset}
  urls+=("$release_url")
  if [ -z "${PHP_DARWIN_RELEASE_URL:-}" ] || [ -n "${PHP_DARWIN_MIRROR_URL:-}" ]; then
    mirror_url=$(php_darwin_release_mirror "$release_repository" "$version") || return 1
    [ -z "$mirror_url" ] || urls+=("$mirror_url/$manifest_download_asset")
    if [ -n "$mirror_url" ] && [ "${PHP_DARWIN_PREFER_MIRROR:-false}" = true ]; then
      urls=("$mirror_url/$manifest_download_asset" "$release_url")
    fi
  fi
  release_archive_error=not-found
  for release_url in "${urls[@]}"; do
    destination=$archive
    [ -z "$resume_bytes" ] || destination="$archive.remaining"
    request_result=0
    archive_http_status=$(php_darwin_request_release "$release_url" "$destination" \
      1024 10 300 "$resume_bytes") || request_result=$?
    if [ "$request_result" -ne 0 ]; then
      [ "$release_archive_error" = checksum ] || release_archive_error=download
      if [ "$archive_http_status" = 200 ] && [ -s "$archive" ] && [ -z "$resume_bytes" ]; then
        received_bytes=$(wc -c < "$archive" | tr -d '[:space:]')
        if [ "$received_bytes" -lt "$manifest_archive_bytes" ]; then
          # A known incomplete prefix cannot match the digest. Start the mirror
          # immediately and authenticate the complete combined archive below.
          resume_bytes=$received_bytes
        elif [ "$received_bytes" -eq "$manifest_archive_bytes" ]; then
          # A timeout can arrive after the last byte. Still require its digest;
          # a corrupt complete response must restart at the next origin.
          php_darwin_start_archive_hash "$archive"
          php_darwin_wait_for_archive_hash
          if [ "$actual_hash" = "$expected_hash" ]; then release_archive_error=; return 0; fi
          release_archive_error=checksum
        fi
      fi
      continue
    fi
    if [ -n "$resume_bytes" ]; then
      case "$archive_http_status" in
        206) cat "$destination" >> "$archive" || return 1 ;;
        # Range is optional at the origin. A full response replaces the prefix.
        200) mv "$destination" "$archive" || return 1 ;;
      esac
    fi
    if [ "$archive_http_status" != 200 ] && \
      { [ "$archive_http_status" != 206 ] || [ -z "$resume_bytes" ]; }; then
      if [ "$archive_http_status" != 404 ] && [ "$release_archive_error" != checksum ]; then
        release_archive_error=download
      fi
      continue
    fi
    php_darwin_start_archive_hash "$archive"
    php_darwin_wait_for_archive_hash
    if [ "$actual_hash" = "$expected_hash" ]; then
      release_archive_error=
      return 0
    fi
    printf 'php-darwin: checksum mismatch from %s; trying the next origin\n' "$release_url" >&2
    release_archive_error=checksum
    resume_bytes=
  done
  return 1
}

PHP_DARWIN_PHASE=fetch
metadata_copy="$tmp_dir/cache-metadata.json"
if [ -n "$local_archive" ]; then
  archive=$local_archive
  checksum="$local_archive.sha256"
  external_metadata="$(dirname "$local_archive")/${asset%.tar.zst}.json"
  [ -f "$archive" ] || php_darwin_die "archive not found: $archive"
  [ -f "$checksum" ] || php_darwin_die "checksum not found: $checksum"
  [ -f "$external_metadata" ] || php_darwin_die "metadata not found: $external_metadata"
  expected_hash=$(php_darwin_checksum_from_file "$checksum" "$asset") || \
    php_darwin_die "checksum file does not contain $asset"
  php_darwin_start_archive_hash "$archive"
  cp "$external_metadata" "$metadata_copy" || php_darwin_die 'could not copy external cache metadata'
  php_darwin_wait_for_archive_hash
  [ "$actual_hash" = "$expected_hash" ] || php_darwin_die "checksum mismatch for $asset"
else
  release_repository=${PHP_DARWIN_RELEASE_REPOSITORY:-$package_release_repository}
  [[ "$release_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
    php_darwin_die "invalid release repository: $release_repository"
  release_manifest="$tmp_dir/php-$version-manifest.json"
  if php_darwin_read_config release-manifest.json > "$release_manifest" 2>/dev/null; then
    if php_darwin_use_release_manifest "$release_manifest"; then
      manifest_from_embedded=true
    else
      php_darwin_refresh_release_manifest
    fi
  else
    php_darwin_refresh_release_manifest
  fi
  if ! php_darwin_download_release_archive; then
    if [ "$manifest_from_embedded" = true ] && [ "$release_archive_error" = not-found ] && \
      [ -z "${PHP_DARWIN_RELEASE_URL:-}" ]; then
      printf 'Embedded release archive was retired; retrying with the current release manifest\n' >&2
      php_darwin_refresh_release_manifest
      if ! php_darwin_download_release_archive; then
        case "$release_archive_error" in
          checksum) php_darwin_die "checksum mismatch for the current release archive $asset" ;;
          *) php_darwin_die "could not download the current release archive from $release_url" ;;
        esac
      fi
    else
      case "$release_archive_error" in
        checksum) php_darwin_die "checksum mismatch for $asset" ;;
        *) php_darwin_die "could not download $release_url" ;;
      esac
    fi
  fi
  [ "$actual_hash" = "$expected_hash" ] || php_darwin_die "checksum mismatch for $asset"
  php_darwin_read_metadata "$archive" "$internal_metadata_path" "$metadata_copy" || \
    php_darwin_die 'could not read metadata from the verified release archive'
fi

PHP_DARWIN_PHASE=cache.metadata
expected_metadata_commit=${HOMEBREW_PHP_COMMIT:-$manifest_homebrew_commit}
metadata_values=$(php_darwin_validate_cache_metadata "$metadata_copy" "$version" "$build" "$ts" "$arch" \
  "$brew_prefix" "$macos_major" "$expected_metadata_commit" "$manifest_php_src_commit" \
  "$current_version" "$tap_snapshot" "$minimum_macos" "$platform_key" \
  "$manifest_extensions_commit") || \
  php_darwin_die 'cache metadata did not match the runner or request'
IFS=$'\t' read -r metadata_homebrew_commit cached_source_hash target_keg_relative pecl_extension \
  metadata_php_semver <<< "$metadata_values" || \
  php_darwin_die 'could not parse the validated cache metadata'
if [ -n "$manifest_source_hash" ]; then
  [ "$cached_source_hash" = "$manifest_source_hash" ] || \
    php_darwin_die 'cache metadata source hash does not match the release manifest'
  [ "$metadata_php_semver" = "$manifest_php_semver" ] || \
    php_darwin_die 'cache PHP version does not match the release manifest'
fi

existing_kegs="$tmp_dir/existing-kegs.txt"
changed_formulae_file="$tmp_dir/changed-formulae.txt"
packages_file="$tmp_dir/packages.tsv"
package_kegs_file="$tmp_dir/package-kegs.txt"
links_file="$tmp_dir/links.tsv"
installed_links_file="$tmp_dir/installed-links.tsv"
managed_paths_file="$tmp_dir/managed-paths.txt"
exclude_file="$tmp_dir/existing-paths.txt"
metadata_records_file="$tmp_dir/metadata-records.tsv"
state_paths_inventory="$tmp_dir/state-paths-inventory.txt"
extension_paths_inventory="$tmp_dir/extension-paths-inventory.tsv"
tap_formulae_file="$tmp_dir/tap-formulae.txt"
: > "$packages_file" || php_darwin_die 'could not create the Homebrew package receipt list'
: > "$package_kegs_file" || php_darwin_die 'could not create the Homebrew keg path list'
: > "$managed_paths_file" || php_darwin_die 'could not create the managed archive path list'
: > "$links_file" || php_darwin_die 'could not create the Homebrew link list'
: > "$installed_links_file" || php_darwin_die 'could not create the installed Homebrew link list'
: > "$state_paths_inventory" || php_darwin_die 'could not create the Homebrew state path list'
: > "$extension_paths_inventory" || php_darwin_die 'could not create the cached extension path list'
jq -er '
  if ((.tap_formulae // []) | length) > 0 then .tap_formulae[] else .formula end
' "$metadata_copy" > "$tap_formulae_file" || \
  php_darwin_die 'could not read embedded custom-tap formulae'
jq -r '[
    (.packages[] | ["package", .name, .opt_target, (.keg_only | tostring)]),
    (.packages[] | ["keg", (.opt_target | ltrimstr("../"))]),
    (.links[] | ["managed", .path]),
    ((.extensions // [])[] | ["extension", .name, .type, .path]),
    ((.extensions // [])[] | ["managed", .path]),
    (.packages[] | ["managed", ("opt/" + .name)]),
    (.links[] | ["link", .path, .target])
  ][] | @tsv' "$metadata_copy" > "$metadata_records_file" || \
  php_darwin_die 'could not read embedded Homebrew installation records'
awk -F '\t' -v packages="$packages_file" -v kegs="$package_kegs_file" \
  -v extensions="$extension_paths_inventory" -v managed="$managed_paths_file" -v links="$links_file" '
  $1 == "package" && NF == 4 { print $2 "\t" $3 "\t" $4 > packages; next }
  $1 == "keg" && NF == 2 { print $2 > kegs; next }
  $1 == "extension" && NF == 4 { print $2 "\t" $3 "\t" $4 > extensions; next }
  $1 == "managed" && NF == 2 { print $2 > managed; next }
  $1 == "link" && NF == 3 { print $2 "\t" $3 > links; next }
  { exit 1 }
' "$metadata_records_file" || php_darwin_die 'could not split embedded Homebrew installation records'
jq -er '.state_paths[]' "$metadata_copy" > "$state_paths_inventory" || \
  php_darwin_die 'could not read embedded Homebrew state paths'
cat "$state_paths_inventory" >> "$managed_paths_file" || \
  php_darwin_die 'could not add embedded Homebrew state paths'
while IFS= read -r state_path; do
  if [ ! -e "$brew_prefix/$state_path" ] && [ ! -L "$brew_prefix/$state_path" ]; then
    printf '%s\n' "$state_path" >> "$new_state_paths_file" || \
      php_darwin_die "could not record new Homebrew state path: $state_path"
  fi
done < "$state_paths_inventory"
# The first two metadata columns are validated above; only the path is needed here.
# shellcheck disable=SC2034
while IFS=$'\t' read -r extension extension_type extension_path; do
  [ -n "$extension_path" ] || continue
  if [ ! -e "$brew_prefix/$extension_path" ] && [ ! -L "$brew_prefix/$extension_path" ]; then
    printf '%s\n' "$extension_path" >> "$new_state_paths_file" || \
      php_darwin_die "could not record new cached extension path: $extension_path"
  fi
done < "$extension_paths_inventory"

PHP_DARWIN_PHASE=homebrew.prepare.wait
php_darwin_wait_for_homebrew_prepare
case "$tap_path" in
  "$brew_prefix/Library/Taps/"*|"$brew_prefix/Homebrew/Library/Taps/"*) ;;
  *) php_darwin_die "unexpected Homebrew tap path: $tap_path" ;;
esac
[ ! -L "$tap_path" ] || php_darwin_die "Homebrew tap path is a symlink: $tap_path"
tap_path_backup=$(php_darwin_tap_backup_path "$brew_prefix" "$tap_path" "$tmp_dir") || \
  php_darwin_die 'could not resolve the Homebrew tap backup path'
tap_path_state=$(php_darwin_prepare_tap_path "$tap_path" "$tap_path_backup") || \
  php_darwin_die "could not prepare the $tap tap path"
case "$tap_path_state" in
  backed-up) tap_path_backed_up=true ;;
  absent|git) ;;
  *) php_darwin_die "invalid $tap tap-path state: $tap_path_state" ;;
esac

formula_trust_references=()
if [ "$tap_was_trusted" = false ]; then
  while IFS= read -r package_name; do
    formula_reference="$tap/$package_name"
    grep -Fxq "$formula_reference" "$initial_formula_trust_file" || \
      formula_trust_references+=("$formula_reference")
  done < "$tap_formulae_file"
fi

PHP_DARWIN_PHASE=cache.validation

# Keep older kegs side-by-side as Homebrew does during an upgrade. An exact
# cached keg must be removed before extraction; otherwise Homebrew only needs
# to unlink the active PHP formulae. Formula-managed post-install state is
# moved aside so the cache can replace it and restore it if installation fails.
PHP_DARWIN_PHASE=homebrew.prepare
if [ -e "$tap_snapshot_path" ] || [ -L "$tap_snapshot_path" ]; then
  [ -d "$tap_snapshot_path" ] && [ ! -L "$tap_snapshot_path" ] || \
    php_darwin_die "Homebrew tap snapshot path is not a directory: $tap_snapshot"
  mv "$tap_snapshot_path" "$tap_snapshot_backup" || \
    php_darwin_die 'could not back up the existing Homebrew tap snapshot'
  tap_snapshot_backed_up=true
fi
if [ -d "$brew_prefix/$target_keg_relative" ]; then
  target_opt_path="$brew_prefix/opt/$formula"
  if [ -L "$target_opt_path" ]; then
    target_opt_previous=$(readlink "$target_opt_path") || \
      php_darwin_die "could not read the existing Homebrew opt link for $formula"
    case "$target_opt_previous" in "../Cellar/$formula/"*) ;; *)
      php_darwin_die "unsupported existing Homebrew opt link for $formula: $target_opt_previous"
      ;;
    esac
    printf '%s\t%s\n' "$formula" "$target_opt_previous" >> "$previous_opt_links" || \
      php_darwin_die "could not preserve the existing Homebrew opt link for $formula"
  fi
  mv "$brew_prefix/$target_keg_relative" "$target_keg_backup" || \
    php_darwin_die "could not back up the existing cached $formula keg"
  target_keg_backed_up=true
fi
php_darwin_postinstall_paths "$version" "$formula" "$build" "$ts" > "$postinstall_candidates_file" || \
  php_darwin_die 'could not resolve formula-managed post-install paths'
: > "$postinstall_paths_file" || php_darwin_die 'could not create the post-install path list'
while IFS= read -r postinstall_path; do
  if grep -Fxq "$postinstall_path" "$state_paths_inventory"; then
    printf '%s\n' "$postinstall_path" >> "$postinstall_paths_file" || \
      php_darwin_die "could not record $postinstall_path"
  else
    case "$postinstall_path" in */pear.conf)
      php_darwin_die "cache metadata omitted $postinstall_path"
      ;;
    esac
  fi
done < "$postinstall_candidates_file"
mkdir -p "$postinstall_backup_dir" || php_darwin_die 'could not create the post-install backup directory'
while IFS= read -r postinstall_path; do
  [ -n "$postinstall_path" ] || continue
  if [ -e "$brew_prefix/$postinstall_path" ] || [ -L "$brew_prefix/$postinstall_path" ]; then
    mkdir -p "$postinstall_backup_dir/${postinstall_path%/*}" || \
      php_darwin_die "could not prepare the backup for $postinstall_path"
    mv "$brew_prefix/$postinstall_path" "$postinstall_backup_dir/$postinstall_path" || \
      php_darwin_die "could not back up $postinstall_path"
  fi
done < "$postinstall_paths_file"
if [ -e "$brew_prefix/$pear_path" ] || [ -L "$brew_prefix/$pear_path" ]; then
  mv "$brew_prefix/$pear_path" "$pear_backup" || php_darwin_die "could not back up $pear_path"
  pear_backed_up=true
fi
rm -f "$brew_prefix/$internal_metadata_path" || php_darwin_die 'could not remove stale archive metadata'
printf '%s\n' "$internal_metadata_path" >> "$managed_paths_file" || \
  php_darwin_die 'could not add the embedded metadata path'
printf '%s\n' "$pear_path" >> "$managed_paths_file" || \
  php_darwin_die 'could not add the formula-managed PEAR path'
printf '%s\n' "$tap_snapshot" >> "$managed_paths_file" || \
  php_darwin_die 'could not add the Homebrew tap snapshot path'
cat "$postinstall_paths_file" >> "$managed_paths_file" || \
  php_darwin_die 'could not add formula-managed post-install paths'
LC_ALL=C sort -u "$managed_paths_file" -o "$managed_paths_file" || \
  php_darwin_die 'could not sort managed archive paths'
# Active Homebrew records are normally unlinked by preparation. Also handle
# stale command links without a linked-keg record, before exclusion inventory.
php_darwin_php_command_links prepare "$brew_prefix" "$command_links_journal" "$links_file" "$formula" || \
  php_darwin_die 'could not prepare the archived PHP command links'
php_darwin_existing_paths "$brew_prefix" "$exclude_file" \
  "$archive_roots_file" \
  "$existing_kegs" "$managed_paths_file" "$package_kegs_file" || \
  php_darwin_die 'could not record existing Homebrew paths'
dependency_links_file="$tmp_dir/dependency-links.txt"
php_darwin_install_state plan "$brew_prefix" \
  "$packages_file" "$existing_kegs" "$changed_formulae_file" "$dependency_links_file" || \
  php_darwin_die 'could not plan cached Homebrew package changes'
while IFS= read -r package_name; do
  [ "$package_name" = "$formula" ] || linked_dependency_references+=("$package_name")
done < "$dependency_links_file"
[ -s "$changed_formulae_file" ] || php_darwin_die 'cache extraction would not add any Homebrew kegs'
grep -Fxq "$formula" "$changed_formulae_file" || php_darwin_die "cache extraction would not add $formula"
if [ "${#linked_dependency_references[@]}" -gt 0 ]; then
  PHP_DARWIN_PHASE=homebrew.unlink
  PHP_DARWIN_UNLINK_PATHS_FILE="$managed_paths_file" \
    php_darwin_unlink_formulae "$dependency_unlink_mode_file" "${linked_dependency_references[@]}" >/dev/null || \
    php_darwin_die 'could not unlink the existing Homebrew dependencies'
  # Unlinked paths must be eligible for extraction and link verification.
  php_darwin_existing_paths "$brew_prefix" "$exclude_file" \
    "$archive_roots_file" "$existing_kegs" "$managed_paths_file" "$package_kegs_file" || \
    php_darwin_die 'could not refresh existing Homebrew paths after dependency unlinking'
fi

# Preserved PEAR and configuration files were moved aside for rollback. Do not
# extract replacement copies that would immediately be discarded on success.
if [ "$pear_backed_up" = true ]; then
  printf '%s\n' "$pear_path" >> "$exclude_file" || exit 1
fi
while IFS= read -r postinstall_path; do
  if [ -e "$postinstall_backup_dir/$postinstall_path" ] || [ -L "$postinstall_backup_dir/$postinstall_path" ]; then
    printf '%s\n' "$postinstall_path" >> "$exclude_file" || exit 1
  fi
done < "$postinstall_paths_file"
# Existing paths (including complete excluded subtrees) remain user-owned.
# Verify and roll back only links the cache will add.
awk -F '\t' '
  FILENAME == ARGV[1] { excluded[$0]=1; next }
  {
    path=$1
    while (1) {
      if (path in excluded) next
      if (!sub("/[^/]+$", "", path)) break
    }
    print
  }
' "$exclude_file" "$links_file" > "$installed_links_file" || \
  php_darwin_die 'could not select Homebrew links installed by the cache'
[ -s "$installed_links_file" ] || php_darwin_die 'cache extraction would not add any Homebrew links'

PHP_DARWIN_PHASE=archive.extract
archive_mutation_started=true
tap_snapshot_extracted=true
php_darwin_extract "$archive" "$brew_prefix" "$exclude_file" \
  "$managed_paths_file" "$package_kegs_file" || \
  php_darwin_die "could not extract $asset into Homebrew"

PHP_DARWIN_PHASE=homebrew.tap
[ -d "$tap_snapshot_path/.git" ] && [ ! -L "$tap_snapshot_path" ] || \
  php_darwin_die 'cache did not contain a valid Homebrew tap snapshot'
php_darwin_validate_tap "$tap_snapshot_path" "$version" '' \
  "$tap_repository" "$metadata_homebrew_commit" "$tap_branch" >/dev/null || \
  php_darwin_die 'cached Homebrew tap snapshot validation failed'
if [ -e "$tap_path" ]; then
  php_darwin_is_git_worktree "$tap_path" || \
    php_darwin_die "installed Homebrew tap is not a Git repository: $tap_path"
  php_darwin_tap_action "$tap_path" "$tap_snapshot_path" "$version" \
    "$cached_source_hash" "$tap_repository" "$metadata_homebrew_commit" "$tap_branch" \
    > "$tap_action_file" 2> "$tap_log" &
  tap_pid=$!
else
  tap_parent=${tap_path%/*}
  [ ! -L "$tap_parent" ] || php_darwin_die "Homebrew tap owner path is a symlink: $tap_parent"
  mkdir -p "$tap_parent" || php_darwin_die "could not create the Homebrew tap owner path: $tap_parent"
  mv "$tap_snapshot_path" "$tap_path" || php_darwin_die "could not install the $tap snapshot"
  tap_snapshot_extracted=false
  tap_installed=true
fi

PHP_DARWIN_PHASE=homebrew.receipts
metadata="$brew_prefix/$internal_metadata_path"
[ -f "$metadata" ] || php_darwin_die 'cache did not contain embedded installation metadata'
cmp -s "$metadata" "$metadata_copy" || \
  php_darwin_die 'extracted installation metadata changed during archive extraction'
rm -f "$metadata" || php_darwin_die 'could not remove embedded installation metadata'
php_darwin_install_state receipts "$brew_prefix" \
  "$packages_file" "$changed_formulae_file" "$previous_opt_links" || \
  php_darwin_die 'could not install cached Homebrew package opt links'
if [ -n "$tap_pid" ] && [ ! -f "$tap_path/Formula/$formula.rb" ]; then
  php_darwin_wait_for_tap
fi
if [ "$tap_was_trusted" = false ]; then
  php_darwin_wait_for_tap
  PHP_DARWIN_PHASE=homebrew.trust
  if [ "${#formula_trust_references[@]}" -gt 0 ]; then
    printf 'Trusting %s installed Homebrew formula(s) from %s\n' \
      "${#formula_trust_references[@]}" "$tap"
    trust_status=0
    php_darwin_trust_store add "$brew_prefix" "$tap" "$formula_trust_pending" \
      "${formula_trust_references[@]}" || trust_status=$?
    if [ "$trust_status" -eq 78 ]; then
      printf '%s\n' "${formula_trust_references[@]}" > "$formula_trust_pending" || \
        php_darwin_die 'could not record formula trust added by the cache installation'
      brew trust --formula "${formula_trust_references[@]}" || \
        php_darwin_die "could not trust installed Homebrew formulae from $tap"
    elif [ "$trust_status" -ne 0 ]; then
      php_darwin_die "could not merge installed Homebrew formula trust for $tap"
    fi
    mv "$formula_trust_pending" "$formula_trust_marker" || \
      php_darwin_die 'could not commit formula trust added by the cache installation'
  fi
fi
PHP_DARWIN_PHASE=homebrew.dependencies
[ -z "$tap_pid" ] || dependencies_started_with_pending_tap=true
php_darwin_check_installed_dependencies > "$missing_log" 2>&1 &
missing_pid=$!

PHP_DARWIN_PHASE=homebrew.configure
[ "$pear_backed_up" = true ] || [ -d "$brew_prefix/$pear_path" ] || \
  php_darwin_die "cache did not install $pear_path"
while IFS= read -r postinstall_path; do
  [ -n "$postinstall_path" ] || continue
  if [ -e "$postinstall_backup_dir/$postinstall_path" ] || \
    [ -L "$postinstall_backup_dir/$postinstall_path" ]; then
    rm -rf "${brew_prefix:?}/${postinstall_path:?}" || \
      php_darwin_die "could not replace cached $postinstall_path with the existing file"
    mkdir -p "$brew_prefix/${postinstall_path%/*}" || \
      php_darwin_die "could not restore the parent for $postinstall_path"
    mv "$postinstall_backup_dir/$postinstall_path" "$brew_prefix/$postinstall_path" || \
      php_darwin_die "could not preserve $postinstall_path"
    printf '%s\n' "$postinstall_path" >> "$postinstall_restored_file" || \
      php_darwin_die "could not record the restored $postinstall_path"
  fi
done < "$postinstall_paths_file"
if [ "$pear_backed_up" = true ]; then
  rm -rf "${brew_prefix:?}/${pear_path:?}" || php_darwin_die "could not replace cached $pear_path"
  mkdir -p "$brew_prefix/${pear_path%/*}" || php_darwin_die "could not restore the parent for $pear_path"
  mv "$pear_backup" "$brew_prefix/$pear_path" || php_darwin_die "could not preserve $pear_path"
  pear_backed_up=false
  pear_restored=true
fi
mkdir -p "$brew_prefix/lib/php/pecl/$pecl_extension" \
  "$brew_prefix/$pear_path/doc" "$brew_prefix/$pear_path/data" "$brew_prefix/$pear_path/cfg" \
  "$brew_prefix/$pear_path/htdocs" "$brew_prefix/$pear_path/test" || \
  php_darwin_die 'could not create formula-managed PEAR and PECL directories'
# Existing PEAR settings may intentionally use a custom shared directory.
# Validate the archive defaults only when this transaction supplied them.
if ! grep -Fxq "etc/php/$config_id/pear.conf" "$postinstall_restored_file"; then
  [ -s "$brew_prefix/etc/php/$config_id/pear.conf" ] || php_darwin_die 'cache did not install the Homebrew PEAR configuration'
  grep -Fq "$brew_prefix/$pear_path" "$brew_prefix/etc/php/$config_id/pear.conf" || \
    php_darwin_die 'cached PEAR configuration has the wrong shared path'
  grep -Fq "$brew_prefix/lib/php/pecl/$pecl_extension" "$brew_prefix/etc/php/$config_id/pear.conf" || \
    php_darwin_die 'cached PEAR configuration has the wrong extension path'
fi
[ -L "$brew_prefix/opt/$formula/pecl" ] && [ -d "$brew_prefix/opt/$formula/pecl" ] || \
  php_darwin_die 'cached PHP PECL link has no shared directory target'

PHP_DARWIN_PHASE=homebrew.link
php_darwin_verify_links "$brew_prefix" "$installed_links_file" || \
  php_darwin_die 'cached Homebrew links did not match the archive metadata'

PHP_DARWIN_PHASE=runtime.verify
expected_runtime_version=$metadata_php_semver
[ "$channel" != nightly ] || expected_runtime_version="$metadata_php_semver-dev"
php_darwin_verify_runtime "$brew_prefix" "$formula" "$expected_runtime_version" \
  "$extension_paths_inventory" || php_darwin_die 'cached PHP installation validation failed'
PHP_DARWIN_PHASE=homebrew.dependencies
php_darwin_resolve_tap_and_dependencies
runtime_verified=true
PHP_DARWIN_PHASE=homebrew.finalize

if [ "$tap_snapshot_backed_up" = true ]; then
  if { [ ! -e "$tap_snapshot_path" ] && [ ! -L "$tap_snapshot_path" ]; } && \
    { mv "$tap_snapshot_backup" "$tap_snapshot_path" 2>/dev/null || \
      { command -v sudo >/dev/null 2>&1 && sudo -n mv "$tap_snapshot_backup" "$tap_snapshot_path"; }; }; then
    tap_snapshot_backed_up=false
  else
    preserve_tmp_dir=true
    printf 'php-darwin: restore the previous cache tap with: sudo mv %s %s\n' \
      "$tap_snapshot_backup" "$tap_snapshot_path" >&2
  fi
fi
if [ "$tap_restore_after_install" = true ]; then
  # Formula trust is needed only while the temporary cached tap is active.
  # Dependency link operations use bare rack names and do not load core formulae.
  if php_darwin_remove_tap_path "$brew_prefix" "$tap_path"; then
    tap_installed=false
    if php_darwin_restore_tap_path "$tap_path" "$tap_path_backup"; then
      tap_path_backed_up=false
      tap_restore_after_install=false
      if ! php_darwin_restore_formula_trust; then
        preserve_tmp_dir=true
      fi
    else
      printf 'php-darwin: restore the original tap with: sudo mv %s %s\n' \
        "$tap_path_backup" "$tap_path" >&2
    fi
  else
    printf 'php-darwin: remove %s, then restore the original tap with: sudo mv %s %s\n' \
      "$tap_path" "$tap_path_backup" "$tap_path" >&2
  fi
elif [ "$tap_path_backed_up" = true ]; then
  # The new tap is committed at this point. A best-effort cleanup failure must
  # not trigger rollback from a backup that may already be partially removed.
  tap_path_backed_up=false
  tap_installed=false
  php_darwin_remove_tap_backup "$brew_prefix" "$tap_path_backup" || \
    printf 'php-darwin: could not remove the retired Homebrew tap backup: %s\n' \
      "$tap_path_backup" >&2
fi
# Install only after the complete base transaction has passed its runtime and
# preservation checks. A missing or incompatible optional pack leaves normal
# extension installation available to callers such as setup-php.
if [ -n "$extension_prefetch_pid" ]; then
  wait "$extension_prefetch_pid" || true
  extension_prefetch_pid=
  cat "$extension_dir/prefetch.log"
  "$extension_node" "$extension_dir/install-extensions.cjs" activate "$extension_dir" \
    "$metadata_copy" "$brew_prefix/etc/php/$config_id/conf.d" ||
    printf 'php-darwin: optional packs unavailable; using the caller extension installer\n' >&2
fi
printf 'Installed PHP %s (%s, %s, %s) from %s\n' \
  "$expected_runtime_version" "$build" "$ts" "$arch" "$asset"
