#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

manifest=${1:?}
version=${2:?}
source_path=${HOMEBREW_EXTENSIONS_PATH:?}

php_darwin_validate_version "$version"
[ -f "$manifest" ] || php_darwin_die "release manifest is missing: $manifest"
published_hash=$(jq -er '(.extensions_source_hash // "") | select(type == "string" and test("^[0-9a-f]{64}$"))' \
  "$manifest" 2>/dev/null) || published_hash=
if [ -n "$published_hash" ]; then
  printf '%s\n' "$published_hash"
  exit 0
fi

published_commit=$(jq -er '(.homebrew_extensions_commit // "") | select(type == "string" and test("^[0-9a-f]{40}$"))' \
  "$manifest" 2>/dev/null) || published_commit=
[ -n "$published_commit" ] || exit 0
if ! git -C "$source_path" cat-file -e "$published_commit^{commit}" 2>/dev/null; then
  git -C "$source_path" fetch --no-tags --depth=1 origin "$published_commit" || \
    php_darwin_die "could not fetch published homebrew-extensions commit $published_commit"
fi
git -C "$source_path" cat-file -e \
  "$published_commit:Abstract/abstract-php-extension.rb" 2>/dev/null || exit 0
configured_extensions=$(bash "$script_dir/cached-extensions.sh" "$version") || \
  php_darwin_die "could not read cached extensions for PHP $version"
while IFS= read -r extension; do
  git -C "$source_path" cat-file -e \
    "$published_commit:Formula/$extension@$version.rb" 2>/dev/null || exit 0
done <<< "$configured_extensions"
HOMEBREW_EXTENSIONS_REF="$published_commit" \
  bash "$script_dir/extensions-source-hash.sh" "$version"
