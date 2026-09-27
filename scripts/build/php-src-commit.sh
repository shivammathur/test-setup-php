#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

version=${1:?}
tap_path=${HOMEBREW_PHP_PATH:-}
repository=$(php_darwin_package_config tap_repository)
branch=${HOMEBREW_PHP_REF:-$(php_darwin_package_config tap_branch)}
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-php-src.XXXXXX") || \
  php_darwin_die 'could not create the PHP source commit directory'
trap 'rm -rf "$work_dir"' EXIT
commits="$work_dir/commits.txt"

php_darwin_validate_version "$version"
: > "$commits" || php_darwin_die 'could not create the PHP source commit list'

for build in release debug; do
  for ts in nts zts; do
    formula=$(php_darwin_requested_formula "$version" "$build" "$ts")
    formula_file="$work_dir/$formula.rb"
    if [ -n "$tap_path" ]; then
      formula_file="$tap_path/Formula/$formula.rb"
      [ -f "$formula_file" ] || php_darwin_die "could not read $formula from the local tap"
    else
      curl --retry 2 --retry-all-errors -fsSL \
        "${repository/github.com/raw.githubusercontent.com}/$branch/Formula/$formula.rb" \
        -o "$formula_file" || php_darwin_die "could not download $formula"
    fi

    source_urls=$(awk '
      $1 == "url" && $2 ~ /^"https:\/\/github\.com\/php\/php-src\/archive\// {
        value=$2
        sub(/^"/, "", value)
        sub(/"$/, "", value)
        print value
      }
    ' "$formula_file") || php_darwin_die "could not inspect the PHP source URL in $formula"
    [ "$(printf '%s\n' "$source_urls" | awk 'NF { count++ } END { print count+0 }')" -eq 1 ] || \
      php_darwin_die "$formula does not contain exactly one php-src archive URL"
    source_url=$source_urls
    source_path=${source_url#https://github.com/php/php-src/archive/}
    path_commit=${source_path%%.tar.gz*}
    query_commit=${source_url##*commit=}
    expected_url="https://github.com/php/php-src/archive/$path_commit.tar.gz?commit=$query_commit"
    [[ "$path_commit" =~ ^[0-9a-f]{40}$ ]] && [[ "$query_commit" =~ ^[0-9a-f]{40}$ ]] && \
      [ "$path_commit" = "$query_commit" ] && [ "$source_url" = "$expected_url" ] || \
      php_darwin_die "$formula contains an invalid php-src commit URL"
    printf '%s\n' "$path_commit" >> "$commits" || \
      php_darwin_die 'could not record a PHP source commit'
  done
done

LC_ALL=C sort -u "$commits" -o "$commits" || php_darwin_die 'could not sort PHP source commits'
[ "$(awk 'END { print NR+0 }' "$commits")" -eq 1 ] || \
  php_darwin_die "PHP $version formulae do not use the same php-src commit"
IFS= read -r php_src_commit < "$commits" || php_darwin_die 'could not read the PHP source commit'
[[ "$php_src_commit" =~ ^[0-9a-f]{40}$ ]] || php_darwin_die 'the PHP source commit is invalid'
printf '%s\n' "$php_src_commit"
