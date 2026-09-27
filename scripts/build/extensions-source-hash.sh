#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

version=${1:?}
source_path=${HOMEBREW_EXTENSIONS_PATH:?}
source_ref=${HOMEBREW_EXTENSIONS_REF:-}
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-extensions-source.XXXXXX") || \
  php_darwin_die 'could not create the extension source hash directory'
records="$work_dir/records.tsv"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

read_source() {
  local destination=$2
  local relative=$1

  case "$relative" in
    Abstract/abstract-php-extension.rb|Formula/*.rb) ;;
    *) php_darwin_die "invalid cached extension source path: $relative" ;;
  esac
  if [ -n "$source_ref" ]; then
    git -C "$source_path" show "$source_ref:$relative" > "$destination" || \
      php_darwin_die "could not read $relative at homebrew-extensions $source_ref"
  else
    [ -f "$source_path/$relative" ] || php_darwin_die "cached extension source is missing: $relative"
    cp "$source_path/$relative" "$destination" || \
      php_darwin_die "could not stage cached extension source: $relative"
  fi
}

php_darwin_validate_version "$version"
[ -d "$source_path" ] || php_darwin_die "homebrew-extensions path is missing: $source_path"
if [ -n "$source_ref" ]; then
  [[ "$source_ref" =~ ^[0-9a-f]{40}$ ]] || php_darwin_die 'invalid homebrew-extensions source ref'
  git -C "$source_path" cat-file -e "$source_ref^{commit}" 2>/dev/null || \
    php_darwin_die "homebrew-extensions commit is unavailable: $source_ref"
fi

: > "$records" || php_darwin_die 'could not create extension source hash records'
configured_extensions=$(bash "$script_dir/cached-extensions.sh" "$version" records) || \
  php_darwin_die "could not read cached extensions for PHP $version"
[ -n "$configured_extensions" ] || php_darwin_die "no cached extensions are configured for PHP $version"
while IFS=$'\t' read -r extension extension_type; do
  [ -n "$extension" ] && [ -n "$extension_type" ] || \
    php_darwin_die "cached extension configuration is invalid for PHP $version"
  relative="Formula/$extension@$version.rb"
  source_file="$work_dir/$extension.rb"
  read_source "$relative" "$source_file"
  source_hash=$(php_darwin_sha256 "$source_file") || php_darwin_die "could not hash $relative"
  printf 'extension\t%s\t%s\t%s\n' "$extension" "$extension_type" "$source_hash" >> "$records" || \
    php_darwin_die "could not record $extension source metadata"
done <<< "$configured_extensions"

relative=Abstract/abstract-php-extension.rb
source_file="$work_dir/abstract-php-extension.rb"
read_source "$relative" "$source_file"
source_hash=$(php_darwin_sha256 "$source_file") || php_darwin_die "could not hash $relative"
printf 'shared\t%s\n' "$source_hash" >> "$records" || \
  php_darwin_die 'could not record the shared extension source metadata'
LC_ALL=C sort -u "$records" -o "$records" || php_darwin_die 'could not sort extension source metadata'
php_darwin_sha256 "$records" || php_darwin_die 'could not hash extension source metadata'
