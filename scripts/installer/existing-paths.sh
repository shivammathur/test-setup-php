#!/usr/bin/env bash

prefix=${1:?}
output=${2:?}
roots_file=${3:?}
kegs_output=${4:?}
managed_paths_file=${5:?}
package_kegs_file=${6:?}

[ -d "$prefix" ] || {
  printf 'Missing Homebrew prefix: %s\n' "$prefix" >&2
  exit 1
}
[ -f "$roots_file" ] || {
  printf 'Missing archive roots: %s\n' "$roots_file" >&2
  exit 1
}
[ -f "$managed_paths_file" ] || {
  printf 'Missing managed archive paths: %s\n' "$managed_paths_file" >&2
  exit 1
}
[ -f "$package_kegs_file" ] || {
  printf 'Missing package keg paths: %s\n' "$package_kegs_file" >&2
  exit 1
}

append_exclusion() {
  relative_path=$1
  case "$relative_path" in *$'\n'*|*$'\r'*)
    printf 'Unsupported Homebrew path: %s\n' "$relative_path" >&2
    exit 1
    ;;
  esac
  printf '%s\n' "$relative_path" >> "$output" || exit 1
}

: > "$output" || exit 1
: > "$kegs_output" || exit 1
allowed_roots=
while IFS= read -r managed_dir extra; do
  [ -n "$managed_dir" ] || continue
  case "$managed_dir" in \#*) continue ;; esac
  [ -z "$extra" ] || {
    printf 'Invalid archive root: %s %s\n' "$managed_dir" "$extra" >&2
    exit 1
  }
  case "$managed_dir" in Cellar|Frameworks|bin|etc|include|lib|opt|sbin|share|var) ;; *)
    printf 'Unsafe archive root: %s\n' "$managed_dir" >&2
    exit 1
    ;;
  esac
  [ ! -L "$prefix/$managed_dir" ] || {
    printf 'Homebrew archive root is a symlink: %s\n' "$managed_dir" >&2
    exit 1
  }
  allowed_roots="$allowed_roots $managed_dir"
done < "$roots_file"

# The archive only contains kegs named in its package metadata. Inventory
# existing versions for those formulae instead of walking the entire Cellar.
while IFS= read -r package_keg extra; do
  [ -n "$package_keg" ] || continue
  [ -z "$extra" ] && [[ "$package_keg" =~ ^Cellar/[A-Za-z0-9@+._-]+/[^/[:space:]]+$ ]] || {
    printf 'Unsafe package keg path: %s %s\n' "$package_keg" "$extra" >&2
    exit 1
  }
  package_rack=${package_keg%/*}
  [ ! -L "$prefix/$package_rack" ] || {
    printf 'Homebrew formula rack is a symlink: %s\n' "$package_rack" >&2
    exit 1
  }
  if [ -d "$prefix/$package_rack" ]; then
    for existing_keg in "$prefix/$package_rack"/*; do
      [ -d "$existing_keg" ] && [ ! -L "$existing_keg" ] || continue
      existing_keg=${existing_keg#"$prefix"/}
      case "$existing_keg" in *$'\n'*|*$'\r'*|*$'\t'*)
        printf 'Unsupported Homebrew keg path: %s\n' "$existing_keg" >&2
        exit 1
        ;;
      esac
      printf '%s\n' "$existing_keg" >> "$kegs_output" || exit 1
    done
  fi
  if [ -e "$prefix/$package_keg" ] || [ -L "$prefix/$package_keg" ]; then
    append_exclusion "$package_keg"
  fi
done < "$package_kegs_file"

inventory_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-existing.XXXXXX") || exit 1
trap 'rm -rf "$inventory_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# Check each shared file and each distinct ancestor once in native stat. A
# shell lstat/regex loop over thousands of links dominates installs on Intel.
awk -v prefix="$prefix" -v allowed=" $allowed_roots " '
  $0 != "" {
    path=$0
    if (path ~ /[\t\r]/ || path ~ /^\// || path ~ /(^|\/)\.\.($|\/)/ || path ~ /\/\//) {
      print "Unsafe managed archive path: " path > "/dev/stderr"; exit 1
    }
    root=path; sub("/.*", "", root)
    if (root !~ /^[A-Za-z0-9._+-]+$/) {
      print "Unsafe managed archive root: " root > "/dev/stderr"; exit 1
    }
    if (!index(allowed, " " root " ")) {
      print "Managed archive path has a disallowed root: " path > "/dev/stderr"; exit 1
    }
    paths[path]=1
    while (sub("/[^/]+$", "", path)) paths[path]=1
  }
  END { for (path in paths) printf "%s/%s%c", prefix, path, 0 }
' "$managed_paths_file" > "$inventory_dir/paths" || exit 1
case "$(uname -s)" in
  Darwin) stat_options=(-f $'%HT\t%N') ;;
  *) stat_options=(-c $'%F\t%n') ;;
esac
LC_ALL=C xargs -0 stat "${stat_options[@]}" < "$inventory_dir/paths" \
  > "$inventory_dir/existing" 2>/dev/null
stat_status=$?
# Missing files are expected. Other xargs failures (including a missing stat
# executable or a signal) must not turn into an empty successful inventory.
case "$stat_status" in 0|1|123) ;; *) exit 1 ;; esac
awk -F '\t' -v prefix="$prefix/" '
  FILENAME == ARGV[1] { managed[$0]=1; next }
  NF == 2 && index($2, prefix) == 1 {
    path=substr($2, length(prefix)+1)
    if ((path in managed) || tolower($1) == "symbolic link") print path
    next
  }
  { exit 1 }
' "$managed_paths_file" "$inventory_dir/existing" >> "$output" || exit 1

LC_ALL=C sort -u "$output" -o "$output" || exit 1
LC_ALL=C sort -u "$kegs_output" -o "$kegs_output" || exit 1
