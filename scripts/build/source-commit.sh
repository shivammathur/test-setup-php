#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

source_name=${1:-php}
pinned_commit=${PINNED_COMMIT:-}
case "$source_name" in
  php)
    repository=$(php_darwin_package_config tap_repository)
    branch=$(php_darwin_package_config tap_branch)
    source_label=homebrew-php
    ;;
  extensions)
    repository=$(php_darwin_package_config extension_tap_repository)
    branch=$(php_darwin_package_config extension_tap_branch)
    source_label=homebrew-extensions
    ;;
  core)
    repository=https://github.com/Homebrew/homebrew-core.git
    branch=main
    source_label=homebrew-core
    if [ -z "$pinned_commit" ] && [ "${PHP_DARWIN_UPDATE_DEPENDENCIES:-false}" != true ]; then
      pinned_commit=$("${PHP_DARWIN_NODE:-node}" "$script_dir/../cache/approved-dependencies.cjs" core) || exit 1
    fi
    ;;
  *) php_darwin_die 'usage: source-commit.sh [php|extensions|core]' ;;
esac
if [ -n "$pinned_commit" ]; then
  [[ "$pinned_commit" =~ ^[0-9a-f]{40}$ ]] || php_darwin_die "invalid pinned $source_label source commit"
  commit=$pinned_commit
  reference="refs/heads/$branch"
else
remote_data=$(git ls-remote "$repository" "refs/heads/$branch") || \
  php_darwin_die "could not resolve $repository $branch"
IFS=$'\t' read -r commit reference <<< "$remote_data"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || php_darwin_die "$source_label returned an invalid source commit"
[ "$reference" = "refs/heads/$branch" ] || php_darwin_die "$source_label returned an unexpected source reference"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'commit=%s\n' "$commit" >> "$GITHUB_OUTPUT" || php_darwin_die 'could not write the source commit output'
else
  printf '%s\n' "$commit"
fi
