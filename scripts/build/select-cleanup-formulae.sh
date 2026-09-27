#!/usr/bin/env bash

installed=${1:?}
dependencies=${2:?}
output=${3:?}

[ -f "$installed" ] || exit 1
[ -f "$dependencies" ] || exit 1

awk '
  NR == FNR { if (NF) dependencies[$1]=1; next }
  NF && !($1 in dependencies) { print $1 }
' "$dependencies" "$installed" | LC_ALL=C sort -u > "$output"
pipeline_status=("${PIPESTATUS[@]}")
[ "${pipeline_status[0]}" -eq 0 ] && [ "${pipeline_status[1]}" -eq 0 ] || exit 1
