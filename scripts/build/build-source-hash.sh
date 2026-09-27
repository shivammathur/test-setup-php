#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

version=${1:?}
kind=${2:?}
commit=${3:-}
mode=${4:-build}
php_darwin_validate_version "$version"
case "$mode" in raw|build) ;; *) php_darwin_die "invalid build hash mode: $mode" ;; esac
[ -z "$commit" ] || [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || php_darwin_die 'invalid source commit'
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-build-source.XXXXXX") || exit 1
trap 'rm -rf "$work_dir"' EXIT
files=()
case "$kind" in
  php)
    source_path=${HOMEBREW_PHP_PATH:?}
    while read -r build ts; do
      formula=$(php_darwin_formula "$version" "$build" "$ts") || exit 1
      files+=("Formula/$formula.rb")
    done < <(php_darwin_configured_variants)
    ;;
  extensions)
    source_path=${HOMEBREW_EXTENSIONS_PATH:?}
    files+=(Abstract/abstract-php-extension.rb)
    extensions=$(bash "$script_dir/cached-extensions.sh" "$version") || exit 1
    while IFS= read -r extension; do
      files+=("Formula/$extension@$version.rb")
    done <<< "$extensions"
    ;;
  *) php_darwin_die "invalid build input kind: $kind" ;;
esac

# Use the existing raw hash algorithms on an isolated source projection. The
# published integrity hashes and the standalone installer stay unchanged.
mkdir -p "$work_dir/Formula" "$work_dir/Abstract" || exit 1
for relative in "${files[@]}"; do
  destination="$work_dir/$relative"
  if [ -n "$commit" ]; then
    git -C "$source_path" show "$commit:$relative" > "$destination" || \
      php_darwin_die "could not read $relative at $commit"
  else
    cp "$source_path/$relative" "$destination" || php_darwin_die "could not read $relative"
  fi
  if [ "$mode" = build ] && [[ "$relative" = Formula/* ]]; then
    bash "$script_dir/formula-build-inputs.sh" "$destination" > "$destination.inputs" || exit 1
    mv "$destination.inputs" "$destination" || exit 1
  fi
done
case "$kind" in
  php) HOMEBREW_PHP_PATH="$work_dir" bash "$script_dir/../lib/source-hash.sh" "$version" ;;
  extensions)
    HOMEBREW_EXTENSIONS_PATH="$work_dir" HOMEBREW_EXTENSIONS_REF='' \
      bash "$script_dir/extensions-source-hash.sh" "$version"
    ;;
esac
