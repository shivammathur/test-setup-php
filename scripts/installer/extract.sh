#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

archive=${1:?}
prefix=${2:?}
exclude_file=${3:?}
archive_members=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-archive-members.XXXXXX") || exit 1
extract_members=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-extract-members.XXXXXX") || {
  rm -f "$archive_members"
  exit 1
}
permission_records=
extract_exclusions=
extract_inclusions=
stat_style=

path_uid() {
  case "$stat_style" in
    bsd) stat -f '%u' "$1" ;;
    gnu) stat -c '%u' "$1" ;;
  esac
}

path_gid() {
  case "$stat_style" in
    bsd) stat -f '%g' "$1" ;;
    gnu) stat -c '%g' "$1" ;;
  esac
}

path_mode() {
  case "$stat_style" in
    bsd) stat -f '%Lp' "$1" ;;
    gnu) stat -c '%a' "$1" ;;
  esac
}

restore_permissions() {
  local absolute_path
  local changed_owner
  local extra
  local gid
  local mode
  local relative_path
  local status=0
  local uid

  [ -n "$permission_records" ] && [ -s "$permission_records" ] || return 0
  while IFS=$'\t' read -r relative_path uid gid mode changed_owner extra; do
    [ -n "$relative_path" ] && [ -z "$extra" ] || {
      status=1
      continue
    }
    absolute_path="$prefix/$relative_path"
    if [ ! -d "$absolute_path" ] || [ -L "$absolute_path" ]; then
      printf 'Could not restore extraction directory: %s\n' "$relative_path" >&2
      status=1
      continue
    fi
    if ! chmod "$mode" "$absolute_path" 2>/dev/null && \
      ! sudo -n chmod "$mode" "$absolute_path"; then
      printf 'Could not restore extraction permissions: %s\n' "$relative_path" >&2
      status=1
    fi
    if [ "$changed_owner" = true ] && ! sudo -n chown "$uid:$gid" "$absolute_path"; then
      printf 'Could not restore extraction ownership: %s\n' "$relative_path" >&2
      status=1
    fi
  done < "$permission_records"
  [ "$status" -ne 0 ] || : > "$permission_records"
  return "$status"
}

# shellcheck disable=SC2329
cleanup() {
  local temporary_file

  trap '' HUP INT TERM
  restore_permissions || true
  for temporary_file in "$archive_members" "$extract_members" "$permission_records" \
    "$extract_exclusions" "$extract_inclusions"; do
    [ -z "$temporary_file" ] || rm -f "$temporary_file"
  done
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ -f "$archive" ] || {
  printf 'Archive not found: %s\n' "$archive" >&2
  exit 1
}
[ -d "$prefix" ] || {
  printf 'Extraction prefix not found: %s\n' "$prefix" >&2
  exit 1
}
[ -f "$exclude_file" ] || {
  printf 'Extraction exclusion list not found: %s\n' "$exclude_file" >&2
  exit 1
}
case "$(uname -s)" in
  Darwin) stat_style=bsd ;;
  *) stat_style=gnu ;;
esac

tar_version=$(tar --version) || exit 1
if [[ "$tar_version" == *bsdtar* ]] && [ -n "${4:-}" ] && [ -n "${5:-}" ]; then
  # The installer has authenticated the archive and validated its metadata.
  # Shared files are enumerated individually; kegs and the staged tap/PEAR tree
  # are whole subtrees. Existing kegs are excluded and replacement kegs have
  # been moved aside, so only these roots can have pre-existing parents.
  cat "$4" "$5" > "$archive_members" || exit 1
else
  tar --ignore-zeros -tf "$archive" > "$archive_members" || {
    printf 'Could not list archive members: %s\n' "$archive" >&2
    exit 1
  }
fi
extract_exclusions=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-exclusions.XXXXXX") || exit 1
extract_inclusions=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-inclusions.XXXXXX") || exit 1
# Collapse excluded members into the largest wholly excluded subtrees. Passing
# every included file to tar makes its pattern matcher quadratic on large kegs.
# Anchor and escape each exclusion so a prefix link never excludes a same-named
# library inside a newly installed keg.
awk -v exclusions="$extract_exclusions" -v inclusions="$extract_inclusions" '
  function parent(path) { sub("/[^/]+$", "", path); return path }
  function literal(path, result, i, c) {
    for (i=1; i<=length(path); i++) {
      c=substr(path, i, 1)
      if (index("\\[]*?$", c)) result=result "\\"
      result=result c
    }
    return result
  }
  FILENAME == ARGV[1] {
    if ($0 == "" || $0 ~ /[\t\r]/ || $0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ ||
        $0 ~ /(^|\/)\.($|\/)/ || $0 ~ /\/\// || $0 ~ /\/$/) exit 2
    excluded[$0]=1
    next
  }
  {
    path=$0
    if (path == "" || path ~ /[\t\r]/ || path ~ /^\// || path ~ /(^|\/)\.\.($|\/)/ ||
        path ~ /(^|\/)\.($|\/)/ || path ~ /\/\// || path ~ /\/$/) exit 3
    candidate=path
    while (1) {
      if (candidate in excluded) {
        omitted[path]=1
        while (index(path, "/")) { path=parent(path); omitted_parents[path]=1 }
        next
      }
      if (!sub("/[^/]+$", "", candidate)) break
    }
    print path
    included[path]=1
    retained[path]=1
    while (index(path, "/")) { path=parent(path); retained[path]=1 }
  }
  END {
    for (path in omitted) {
      while (index(path, "/") && !(parent(path) in retained)) path=parent(path)
      compact[path]=1
    }
    for (path in compact) print literal(path, "^") > exclusions
    for (path in included) {
      while (index(path, "/") && !(parent(path) in omitted_parents)) path=parent(path)
      compact_included[path]=1
    }
    for (path in compact_included) print literal(path, "") > inclusions
  }
' "$exclude_file" "$archive_members" > "$extract_members"
filter_status=$?
case "$filter_status" in
  0) ;;
  2) printf 'Unsafe extraction exclusion path\n' >&2; exit 1 ;;
  3) printf 'Unsafe archive member\n' >&2; exit 1 ;;
  *) printf 'Could not filter archive members\n' >&2; exit 1 ;;
esac
[ -s "$extract_members" ] || {
  printf 'Archive has no extractable members: %s\n' "$archive" >&2
  exit 1
}

permission_records=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-permissions.XXXXXX") || exit 1
awk '
  {
    path=$0
    while (sub("/[^/]+$", "", path)) print path
  }
' "$extract_members" | LC_ALL=C sort -u > "$archive_members" || exit 1
: > "$permission_records" || exit 1
current_uid=$(id -u) || exit 1
current_gid=$(id -g) || exit 1
while IFS= read -r relative_path; do
  absolute_path="$prefix/$relative_path"
  [ ! -L "$absolute_path" ] || {
    printf 'Extraction parent is a symlink: %s\n' "$relative_path" >&2
    exit 1
  }
  [ -d "$absolute_path" ] || continue
  [ ! -w "$absolute_path" ] || continue
  uid=$(path_uid "$absolute_path") || exit 1
  gid=$(path_gid "$absolute_path") || exit 1
  mode=$(path_mode "$absolute_path") || exit 1
  if [ "$uid" = "$current_uid" ]; then
    changed_owner=false
  else
    changed_owner=true
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$relative_path" "$uid" "$gid" "$mode" \
    "$changed_owner" >> "$permission_records" || exit 1
  if [ "$changed_owner" = true ]; then
    command -v sudo >/dev/null 2>&1 && \
      sudo -n chown "$current_uid:$current_gid" "$absolute_path" || exit 1
  fi
  chmod u+rwx "$absolute_path" || exit 1
  [ -w "$absolute_path" ] || exit 1
done < "$archive_members"

[ ! -s "$permission_records" ] || \
  printf 'Temporarily granting access to protected Homebrew directories\n'
case "$tar_version" in
  *bsdtar*)
    # libarchive scans its patterns for each member. Choose the smaller set of
    # complete subtrees, keeping both forms literal and rooted at the prefix.
    if [ "$(wc -l < "$extract_inclusions")" -lt "$(wc -l < "$extract_exclusions")" ]; then
      extract_options=(-T "$extract_inclusions")
    else
      extract_options=(-X "$extract_exclusions")
    fi
    ;;
  *) extract_options=(-T "$extract_members") ;;
esac
# Archive owner names can trigger slow OpenDirectory lookups on self-hosted
# Macs, even with --no-same-owner. Extraction still belongs to the current user.
tar --ignore-zeros -xkmpf "$archive" --no-same-owner --numeric-owner -C "$prefix" "${extract_options[@]}"
extract_status=$?
restore_permissions || exit 1
exit "$extract_status"
