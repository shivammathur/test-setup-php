#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
prefix=${1:?}
input=${2:?}
output=${3:?}
installed_prefix=${4:-$prefix}
policy=${5:-$script_dir/../../conf/archive-policy.json}
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-filter.XXXXXX") || exit 1
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ -d "$prefix" ] && [ -s "$input" ] && [ "$input" != "$output" ] || exit 1
policy_values=$(jq -er '
  select((.documentation_directories | type == "array" and length > 0 and
    all(.[]; type == "string" and test("^[a-z]+$"))) and
    (.preserve_pattern | type == "string" and length > 0 and test("^[^\\r\\n\\t]+$"))) |
  [(.documentation_directories | join(" ")), .preserve_pattern] | @tsv
' "$policy") || exit 1
IFS=$'\t' read -r directories preserve_pattern <<< "$policy_values" || exit 1
awk '
  $0 == "" || $0 ~ /[\r\t]/ || $0 ~ /^\// || $0 ~ /(^|\/)\.\.?(\/|$)/ ||
    $0 ~ /\/\// || $0 ~ /\/$/ || seen[$0]++ { exit 1 }
' "$input" || { printf 'Unsafe or duplicate archive path\n' >&2; exit 1; }

: > "$work_dir/symlink-paths"
: > "$work_dir/symlink-names"
while IFS= read -r member; do
  [ -L "$prefix/$member" ] || continue
  printf '%s\0' "$prefix/$member" >> "$work_dir/symlink-paths" || exit 1
  printf '%s\n' "$member" >> "$work_dir/symlink-names" || exit 1
done < "$input"
: > "$work_dir/targets"
if [ -s "$work_dir/symlink-paths" ]; then
  case "$(uname -s)" in
    Darwin) xargs -0 stat -f '%Y' < "$work_dir/symlink-paths" > "$work_dir/targets" || exit 1 ;;
    *) xargs -0 readlink < "$work_dir/symlink-paths" > "$work_dir/targets" || exit 1 ;;
  esac
fi
[ "$(wc -l < "$work_dir/targets")" = "$(wc -l < "$work_dir/symlink-names")" ] || exit 1
paste "$work_dir/symlink-names" "$work_dir/targets" > "$work_dir/links" || exit 1
LC_ALL=C awk -F '\t' -v directories="$directories" -v preserve_pattern="$preserve_pattern" \
  -v installed_prefix="$installed_prefix" -f "$script_dir/filter-archive.awk" \
  "$input" "$work_dir/links" > "$work_dir/filtered" || exit 1
[ -s "$work_dir/filtered" ] || exit 1
cp "$work_dir/filtered" "$output"
