#!/usr/bin/env bash

php_darwin_root=${PHP_DARWIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
unset php_darwin_configured_versions_data php_darwin_configured_variants_data

php_darwin_read_config() {
  cat "$php_darwin_root/conf/$1"
}

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
