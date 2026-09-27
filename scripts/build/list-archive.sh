#!/usr/bin/env bash

archive=${1:?}
output=${2:?}

[ -f "$archive" ] || {
  printf 'Archive not found: %s\n' "$archive" >&2
  exit 1
}

tar --ignore-zeros -tf "$archive" > "$output" && [ -s "$output" ]
