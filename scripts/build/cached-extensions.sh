#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

version=${1:?}
output=${2:-names}
php_darwin_validate_version "$version"
case "$output" in names|records) ;; *) php_darwin_die 'usage: cached-extensions.sh VERSION [names|records]' ;; esac

extensions=$(php_darwin_read_config "cached-extensions/$version") || \
  php_darwin_die "cached extensions are not configured for PHP $version"
zend_extensions=$(php_darwin_read_config zend-extensions) || \
  php_darwin_die 'could not read Zend extension names'

# Validate each list before emitting records used by builds and source hashes.
validate_list() {
  local contents=$1 label=$2 name extra seen=
  while read -r name extra; do
    [ -n "$name" ] || continue
    [ -z "$extra" ] && [[ "$name" =~ ^[A-Za-z0-9_]+$ ]] || \
      php_darwin_die "invalid extension name in $label: $name $extra"
    case " $seen " in
      *" $name "*) php_darwin_die "duplicate extension in $label: $name" ;;
    esac
    seen="$seen $name"
  done <<< "$contents"
}
validate_list "$extensions" "cached-extensions/$version"
validate_list "$zend_extensions" zend-extensions
[ -n "${extensions//[[:space:]]/}" ] || php_darwin_die "cached-extension list is empty for PHP $version"

while read -r name; do
  [ -n "$name" ] || continue
  if [ "$output" = records ]; then
    type=extension
    while read -r zend; do
      [ "$name" != "$zend" ] || type=zend_extension
    done <<< "$zend_extensions"
    printf '%s\t%s\n' "$name" "$type"
  else
    printf '%s\n' "$name"
  fi
done <<< "$extensions"
