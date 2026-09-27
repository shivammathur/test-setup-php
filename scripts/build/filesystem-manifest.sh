#!/usr/bin/env bash

prefix=${1:?}
output=${2:?}
roots_file=${3:?}
manifest_tmp=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-manifest.XXXXXX") || exit 1
raw_output="$manifest_tmp/unsorted"
path_list="$manifest_tmp/paths"
file_list="$manifest_tmp/files"
directory_list="$manifest_tmp/directories"
symlink_list="$manifest_tmp/symlinks"
relative_list="$manifest_tmp/relative"
mode_list="$manifest_tmp/modes"
value_list="$manifest_tmp/values"
trap 'rm -f "$raw_output" "$path_list" "$file_list" "$directory_list" "$symlink_list" \
  "$relative_list" "$mode_list" "$value_list"; rmdir "$manifest_tmp" 2>/dev/null || true' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ -d "$prefix" ] || {
  printf 'Missing Homebrew prefix: %s\n' "$prefix" >&2
  exit 1
}
[ -f "$roots_file" ] || {
  printf 'Missing snapshot roots: %s\n' "$roots_file" >&2
  exit 1
}

if stat -f '%Lp' "$prefix" >/dev/null 2>&1; then
  stat_flavor=bsd
else
  stat_flavor=gnu
fi

write_relative_paths() {
  local input=$1
  local path
  local relative

  : > "$relative_list" || return 1
  while IFS= read -r -d '' path; do
    relative=${path#"$prefix"/}
    case "$relative" in *$'\n'*|*$'\r'*|*$'\t'*)
      printf 'Unsupported Homebrew snapshot path: %s\n' "$relative" >&2
      return 1
      ;;
    esac
    printf '%s\n' "$relative" >> "$relative_list" || return 1
  done < "$input"
}

append_entries() {
  local input=$1
  local expected_lines
  local type=$2
  local pipeline_status

  [ -s "$input" ] || return 0
  write_relative_paths "$input" || return 1
  expected_lines=$(wc -l < "$relative_list") || return 1
  expected_lines=${expected_lines//[[:space:]]/}
  if [ "$stat_flavor" = bsd ]; then
    xargs -0 stat -f '%Lp' < "$input" > "$mode_list" || return 1
  else
    xargs -0 stat -c '%a' < "$input" > "$mode_list" || return 1
  fi
  [ "$(wc -l < "$mode_list" | tr -d '[:space:]')" = "$expected_lines" ] || return 1
  case "$type" in
    f)
      xargs -0 shasum -a 256 < "$input" | awk '{ print $1 }' > "$value_list"
      pipeline_status=("${PIPESTATUS[@]}")
      [ "${pipeline_status[0]}" -eq 0 ] && [ "${pipeline_status[1]}" -eq 0 ] || return 1
      [ "$(wc -l < "$value_list" | tr -d '[:space:]')" = "$expected_lines" ] || return 1
      paste "$relative_list" "$mode_list" "$value_list" | \
        awk -F '\t' 'NF == 3 { print $1 "\tf\t" $2 "\t" $3; next } { exit 1 }' >> "$raw_output"
      ;;
    l)
      if [ "$stat_flavor" = bsd ]; then
        xargs -0 stat -f '%Y' < "$input" > "$value_list" || return 1
      else
        xargs -0 readlink < "$input" > "$value_list" || return 1
      fi
      [ "$(wc -l < "$value_list" | tr -d '[:space:]')" = "$expected_lines" ] || return 1
      if grep -Eq $'[\r\t]' "$value_list"; then
        printf 'Unsupported Homebrew snapshot symlink target\n' >&2
        return 1
      fi
      paste "$relative_list" "$mode_list" "$value_list" | \
        awk -F '\t' 'NF == 3 { print $1 "\tl\t" $2 "\t" $3; next } { exit 1 }' >> "$raw_output"
      ;;
    d)
      paste "$relative_list" "$mode_list" | \
        awk -F '\t' 'NF == 2 { print $1 "\td\t" $2; next } { exit 1 }' >> "$raw_output"
      ;;
    *) return 1 ;;
  esac
}

: > "$raw_output" || exit 1
: > "$file_list" || exit 1
: > "$directory_list" || exit 1
: > "$symlink_list" || exit 1
while read -r relative_root extra; do
  [ -n "$relative_root" ] || continue
  case "$relative_root" in \#*) continue ;; esac
  [ -z "$extra" ] || {
    printf 'Invalid snapshot root: %s %s\n' "$relative_root" "$extra" >&2
    exit 1
  }
  case "$relative_root" in /*|*..*)
    printf 'Unsafe snapshot root: %s\n' "$relative_root" >&2
    exit 1
    ;;
  esac
  root="$prefix/$relative_root"
  [ -e "$root" ] || [ -L "$root" ] || continue
  find "$root" \( -path "$prefix/var/homebrew/locks" -o -path "$prefix/var/homebrew/pinned" \) \
    -prune -o -print0 > "$path_list" || exit 1
  while IFS= read -r -d '' path; do
    if [ -L "$path" ]; then
      printf '%s\0' "$path" >> "$symlink_list" || exit 1
    elif [ -f "$path" ]; then
      printf '%s\0' "$path" >> "$file_list" || exit 1
    elif [ -d "$path" ]; then
      printf '%s\0' "$path" >> "$directory_list" || exit 1
    fi
  done < "$path_list"
done < "$roots_file"
append_entries "$file_list" f || exit 1
append_entries "$symlink_list" l || exit 1
append_entries "$directory_list" d || exit 1
LC_ALL=C sort "$raw_output" > "$output" || exit 1
