#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

manifest=${1:?}
version=${2:?}
kind=${3:?}
current=${4:?}
published=${5:-}

if [ "$published" = "$current" ]; then
  printf 'true\n'
  exit 0
fi
if [ -z "$published" ]; then
  printf 'false\n'
  exit 0
fi
case "$kind" in
  php)
    source_path=${HOMEBREW_PHP_PATH:?}
    commit_key=homebrew_php_commit
    ;;
  extensions)
    source_path=${HOMEBREW_EXTENSIONS_PATH:?}
    commit_key=homebrew_extensions_commit
    ;;
  *) php_darwin_die "invalid build input kind: $kind" ;;
esac

commit=$(jq -er --arg key "$commit_key" '.[$key] | select(type == "string" and test("^[0-9a-f]{40}$"))' \
  "$manifest") || php_darwin_die "could not read the published $kind source commit"
if ! git -C "$source_path" cat-file -e "$commit^{commit}" 2>/dev/null; then
  git -C "$source_path" fetch --no-tags --depth=1 origin "$commit" || \
    php_darwin_die "could not fetch the published $kind source commit"
fi

# Verify the old raw hash before comparing projections. This also prevents a
# changed extension list/type from being mistaken for a bottle-only update.
old_raw=$(bash "$script_dir/build-source-hash.sh" "$version" "$kind" "$commit" raw 2>/dev/null) || old_raw=
if [ "$old_raw" != "$published" ]; then
  printf 'false\n'
  exit 0
fi
old_inputs=$(bash "$script_dir/build-source-hash.sh" "$version" "$kind" "$commit") || \
  php_darwin_die "could not hash published $kind build inputs"
current_inputs=$(bash "$script_dir/build-source-hash.sh" "$version" "$kind") || \
  php_darwin_die "could not hash current $kind build inputs"
if [ "$old_inputs" = "$current_inputs" ]; then
  printf 'true\n'
else
  printf 'false\n'
fi
