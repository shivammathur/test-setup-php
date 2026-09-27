#!/usr/bin/env bash

prefix=${1:?}
verify_links_file=${2:?}
actual_links=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-links.XXXXXX") || exit 1
raw_links=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-raw-links.XXXXXX") || {
  rm -f "$actual_links"
  exit 1
}
trap 'rm -f "$actual_links" "$raw_links"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ -d "$prefix" ] || {
  printf 'Missing Homebrew prefix: %s\n' "$prefix" >&2
  exit 1
}
[ -s "$verify_links_file" ] || {
  printf 'Missing Homebrew link manifest: %s\n' "$verify_links_file" >&2
  exit 1
}

link_paths=()
while IFS=$'\t' read -r link_relative link_target extra; do
  [ -n "$link_relative" ] && [ -n "$link_target" ] && [ -z "$extra" ] || {
    printf 'Invalid Homebrew link record: %s\n' "$link_relative" >&2
    exit 1
  }
  [ -L "$prefix/$link_relative" ] || {
    printf 'Cached Homebrew link is missing or conflicted: %s\n' "$link_relative" >&2
    exit 1
  }
  link_paths+=("$prefix/$link_relative")
done < "$verify_links_file"

if [ "$(uname -s)" = Darwin ]; then
  stat -f $'%N\t%Y' "${link_paths[@]}" > "$raw_links" || exit 1
  awk -F '\t' -v prefix="$prefix/" '
    index($1, prefix) == 1 && NF == 2 { print substr($1, length(prefix) + 1) "\t" $2; next }
    { exit 1 }
  ' "$raw_links" > "$actual_links" || exit 1
else
  : > "$actual_links" || exit 1
  while IFS=$'\t' read -r link_relative link_target extra; do
    printf '%s\t%s\n' "$link_relative" "$(readlink "$prefix/$link_relative")" >> "$actual_links" || exit 1
  done < "$verify_links_file"
fi

if ! cmp -s "$verify_links_file" "$actual_links"; then
  diff -u "$verify_links_file" "$actual_links" >&2 || true
  printf 'Cached Homebrew links do not match the archive manifest\n' >&2
  exit 1
fi
