#!/usr/bin/env bash

dependencies=${1:?}
installed=${2:?}
formula=${3:?}
output=${4:?}

[ -s "$dependencies" ] || exit 1
[ -f "$installed" ] || exit 1
[[ "$formula" =~ ^[A-Za-z0-9@+._-]+$ ]] || exit 1
awk 'NF != 1 || $1 !~ /^[A-Za-z0-9@+._-]+$/ { exit 1 }' "$dependencies" || exit 1

awk -v formula="$formula" '
  FILENAME == ARGV[1] { dependencies[$1]=1; next }
  !NF { next }
  {
    installed[$1]=1
    if ($1 == formula || ($1 in dependencies && $1 != "zstd")) print $1
  }
  END {
    if (!(formula in installed)) exit 1
    for (dependency in dependencies) {
      if (dependency != "zstd" && !(dependency in installed)) exit 1
    }
  }
' "$dependencies" "$installed" | LC_ALL=C sort -u > "$output"
pipeline_status=("${PIPESTATUS[@]}")
[ "${pipeline_status[0]}" -eq 0 ] && [ "${pipeline_status[1]}" -eq 0 ] || exit 1
grep -Fxq "$formula" "$output"
