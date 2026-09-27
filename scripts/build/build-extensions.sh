#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"
php_darwin_configure_homebrew_environment
export HOMEBREW_VERBOSE=1 HOMEBREW_VERBOSE_USING_DOTS=0

version=${PHP_VERSION:?}
build=${BUILD:?}
ts=${TS:?}
source_commit=${HOMEBREW_EXTENSIONS_COMMIT:?}
formula=$(php_darwin_formula "$version" "$build" "$ts") || exit 1
config_id=$(php_darwin_config_id "$version" "$build" "$ts") || exit 1
suffix=$(php_darwin_formula_suffix "$build" "$ts") || exit 1
extension_tap=$(php_darwin_package_config extension_tap) || exit 1
extension_repository=$(php_darwin_package_config extension_tap_repository) || exit 1
brew_prefix=$(brew --prefix) || php_darwin_die 'could not resolve the Homebrew prefix'
work_dir="${RUNNER_TEMP:-/tmp}/php-darwin-build"
paths_file="$work_dir/cached-extension-paths.txt"
abstract_backup="$work_dir/abstract-php-extension.rb"
abstract_file=
extension_tap_path=
extension_dir=
extensions=()
extension_formulae=()
extension_references=()
extension_types=()
cached_paths=()
if [ -n "${EXTENSION_PACK:-}" ]; then
  configured_extensions=$(jq -er --arg name "$EXTENSION_PACK" --arg version "$version" '
    select(.versions | index($version)) | .packs[$name] | select(type == "array" and length > 0) |
    .[] | [.,"extension"] | @tsv' "$script_dir/../../conf/extension-packs.json") || \
    php_darwin_die 'invalid optional extension pack'
else
  configured_extensions=$(bash "$script_dir/cached-extensions.sh" "$version" records) || \
    php_darwin_die "could not read cached extensions for PHP $version"
fi

remove_extension_configs() {
  local config_dir="$brew_prefix/etc/php/$config_id/conf.d"
  local config_file
  local config_files=()
  local config_list="$work_dir/extension-configs.bin"
  local extension

  [ -d "$config_dir" ] || return 0
  : > "$config_list" || return 1
  for extension in "${extensions[@]}"; do
    find "$config_dir" -maxdepth 1 -type f -name "*$extension*.ini" -print0 \
      >> "$config_list" || return 1
  done
  while IFS= read -r -d '' config_file; do
    config_files+=("$config_file")
  done < "$config_list"
  rm -f "$config_list" || return 1
  [ "${#config_files[@]}" -gt 0 ] || return 0
  if [ -w "$config_dir" ]; then
    rm -f "${config_files[@]}"
  else
    command -v sudo >/dev/null 2>&1 && sudo -n rm -f "${config_files[@]}"
  fi
}

cleanup() {
  local cleanup_status=$?
  local cached_path

  trap - EXIT
  trap '' HUP INT TERM
  if [ -n "$abstract_file" ] && [ -f "$abstract_backup" ]; then
    mv "$abstract_backup" "$abstract_file" || cleanup_status=1
  fi
  if [ "${#extension_formulae[@]}" -gt 0 ]; then
    brew uninstall --force --ignore-dependencies "${extension_formulae[@]}" >/dev/null 2>&1 || true
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    for cached_path in "${cached_paths[@]}"; do
      case "$cached_path" in
        "$brew_prefix"/*)
          if [ -w "${cached_path%/*}" ]; then
            rm -f "$cached_path" >/dev/null 2>&1 || true
          else
            sudo -n rm -f "$cached_path" >/dev/null 2>&1 || true
          fi
          ;;
      esac
    done
  fi
  remove_extension_configs >/dev/null 2>&1 || cleanup_status=1
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

php_darwin_validate_build "$build"
php_darwin_validate_ts "$ts"
[ "$(uname -s)" = Darwin ] || php_darwin_die 'cached extension builds require macOS'
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || php_darwin_die 'invalid homebrew-extensions source commit'
mkdir -p "$work_dir" || php_darwin_die 'could not create the extension build directory'
: > "$paths_file" || php_darwin_die 'could not create the cached extension path list'

while IFS=$'\t' read -r extension extension_type; do
  if [ -n "$extension" ] && [ -n "$extension_type" ]; then
    extensions+=("$extension")
    extension_formulae+=("$extension@$version")
    extension_references+=("$extension_tap/$extension@$version")
    extension_types+=("$extension_type")
  fi
done <<< "$configured_extensions"
[ "${#extension_formulae[@]}" -gt 0 ] || php_darwin_die "no cached extensions are configured for PHP $version"

brew tap "$extension_tap" || php_darwin_die "could not tap $extension_tap"
brew trust "$extension_tap" || php_darwin_die "could not trust $extension_tap"
extension_tap_path=$(brew --repository "$extension_tap") || \
  php_darwin_die "could not resolve the $extension_tap repository"
[ "$(git -C "$extension_tap_path" remote get-url origin)" = "$extension_repository" ] || \
  php_darwin_die 'homebrew-extensions has an unexpected origin'
if ! git -C "$extension_tap_path" cat-file -e "$source_commit^{commit}" 2>/dev/null; then
  git -C "$extension_tap_path" fetch --depth=1 origin "$source_commit" || \
    php_darwin_die "could not fetch homebrew-extensions commit $source_commit"
fi
git -C "$extension_tap_path" checkout --detach "$source_commit" || \
  php_darwin_die "could not pin homebrew-extensions at $source_commit"

# PHP 8.5 is named php, not php@8.5; resolving the dependency alias is not
# enough because Homebrew's formula_opt_bin uses the requested name literally.
abstract_file="$extension_tap_path/Abstract/abstract-php-extension.rb"
[ -f "$abstract_file" ] || php_darwin_die 'homebrew-extensions abstract formula is missing'
cp "$abstract_file" "$abstract_backup" || php_darwin_die 'could not back up the extension formula base'
php_darwin_select_ruby
"$PHP_DARWIN_RUBY" "$script_dir/extension-formula.rb" "$abstract_file" "$formula" "$config_id" "$version" || \
  php_darwin_die 'could not select the restored PHP formula for extensions'

# Formula names do not encode the PHP debug/ZTS variant. A persistent runner
# can retain a keg from another build, so let the bottle cache select the exact
# variant instead of treating that keg as an already satisfied target.
for extension_reference in "${extension_references[@]}"; do
  if brew list --versions "$extension_reference" >/dev/null 2>&1; then
    brew uninstall --force --ignore-dependencies "$extension_reference" || \
      php_darwin_die "could not clear the previous extension build: $extension_reference"
  fi
done

if [ -n "${PHP_DARWIN_SOURCE_CACHE_NODE:-}" ]; then
  "$PHP_DARWIN_SOURCE_CACHE_NODE" "${PHP_DARWIN_SOURCE_CACHE_ACTION:?}" install-extensions \
    "$extension_tap_path/Abstract/abstract-php-extension.rb" "$brew_prefix/opt/$formula" \
    "${extension_references[@]}" || php_darwin_die "could not cache PHP $version extension bottles"
elif [ -n "$suffix" ]; then
  brew install --verbose --build-from-source --skip-link \
    "${extension_references[@]}" || \
    php_darwin_die "could not build cached PHP $version extensions"
else
  # Homebrew pours compatible bottles and builds only unavailable formulae.
  brew install --verbose --skip-link \
    "${extension_references[@]}" || \
    php_darwin_die "could not install cached PHP $version extensions"
fi

extension_dir=$("$brew_prefix/opt/$formula/bin/php-config" --extension-dir) || \
  php_darwin_die 'could not resolve the PHP extension directory'
case "$extension_dir" in "$brew_prefix"/*) ;; *) php_darwin_die "extension directory is outside Homebrew: $extension_dir" ;; esac
[ ! -L "$extension_dir" ] || php_darwin_die "extension directory is a symlink: $extension_dir"
if [ ! -d "$extension_dir" ]; then
  extension_parent=${extension_dir%/*}
  if [ -d "$extension_parent" ] && [ -w "$extension_parent" ]; then
    mkdir -p "$extension_dir" || php_darwin_die 'could not create the PHP extension directory'
  else
    command -v sudo >/dev/null 2>&1 || php_darwin_die 'sudo is required for the protected PHP extension directory'
    sudo -n mkdir -p "$extension_dir" || \
      php_darwin_die 'could not create the protected PHP extension directory'
  fi
fi
extension_dir=$(cd "$extension_dir" && pwd -P) || \
  php_darwin_die 'could not resolve the physical PHP extension directory'
case "$extension_dir" in "$brew_prefix"/*) ;; *)
  php_darwin_die "physical extension directory is outside Homebrew: $extension_dir"
  ;;
esac

extension_index=0
for extension_formula in "${extension_formulae[@]}"; do
  extension=${extension_formula%@*}
  extension_type=${extension_types[$extension_index]}
  extension_index=$((extension_index + 1))
  source_module="$brew_prefix/opt/$extension_formula/$extension.so"
  cached_module="$extension_dir/$extension.so"
  [ -f "$source_module" ] && [ ! -L "$source_module" ] || \
    php_darwin_die "cached extension module is missing: $source_module"
  if [ -w "$extension_dir" ]; then
    install -m 0644 "$source_module" "$cached_module" || \
      php_darwin_die "could not cache $extension for PHP $version"
  else
    command -v sudo >/dev/null 2>&1 || \
      php_darwin_die 'sudo is required for the protected PHP extension directory'
    sudo -n install -m 0644 "$source_module" "$cached_module" || \
      php_darwin_die "could not cache $extension in the protected PHP extension directory"
  fi
  cached_paths+=("$cached_module")
  printf '%s\t%s\t%s\n' "$extension" "$extension_type" \
    "${cached_module#"$brew_prefix"/}" >> "$paths_file" || \
    php_darwin_die "could not record cached $extension"
  extension_load_args=()
  if [ -n "${EXTENSION_PACK:-}" ]; then
    for load_index in "${!cached_paths[@]}"; do
      extension_load_args+=(-d "${extension_types[$load_index]}=${cached_paths[$load_index]}")
    done
  else
    extension_load_args=(-d "$extension_type=$cached_module")
  fi
  "$brew_prefix/opt/$formula/bin/php" -n "${extension_load_args[@]}" -r \
    "if (!extension_loaded('$extension')) { exit(1); }" || \
    php_darwin_die "$extension does not load with PHP $version $build/$ts"
done

LC_ALL=C sort -u "$paths_file" -o "$paths_file" || \
  php_darwin_die 'could not sort cached extension paths'
if [ -n "${EXTENSION_PACK:-}" ]; then
  "${PHP_DARWIN_NODE:-node}" "$script_dir/extension-pack.cjs" "$extension_dir" "$brew_prefix/opt/$formula/bin/php" || \
    php_darwin_die "could not package $EXTENSION_PACK"
fi
brew uninstall --force --ignore-dependencies "${extension_formulae[@]}" || \
  php_darwin_die 'could not remove temporary extension formulae'
extension_formulae=()
remove_extension_configs || php_darwin_die 'could not remove cached extension configuration files'
for extension in "${extensions[@]}"; do
  if "$brew_prefix/opt/$formula/bin/php" -n -r \
    "if (extension_loaded('$extension')) { exit(1); }"; then
    :
  else
    php_darwin_die "$extension is built into PHP unexpectedly"
  fi
  if "$brew_prefix/opt/$formula/bin/php" -r \
    "if (extension_loaded('$extension')) { exit(1); }"; then
    :
  else
    php_darwin_die "$extension is enabled by default after caching"
  fi
done
if [ -n "$abstract_file" ]; then
  mv "$abstract_backup" "$abstract_file" || php_darwin_die 'could not restore the extension formula base'
  abstract_file=
fi
printf 'Cached %s for PHP %s (%s, %s)\n' "$(tr '\n' ' ' < "$paths_file")" "$version" "$build" "$ts"
