#!/usr/bin/env bash

# Transfer commands only. Callers retain validation and commit ordering.
# Capture stdout separately for each attempt so partial JSON is never appended.
php_darwin_retry() {
  local attempt=1 result output
  while :; do
    result=0
    output=$("$@") || result=$?
    if [ "$result" -eq 0 ]; then
      [ -z "$output" ] || printf '%s\n' "$output"
      return 0
    fi
    [ "$attempt" -lt 3 ] || return "$result"
    printf '%s failed; retry %s/3\n' "$1" "$((attempt + 1))" >&2
    sleep "$((1 << (attempt - 1)))"
    attempt=$((attempt + 1))
  done
}

php_darwin_upload_immutable() {
  local tag=$1 repository=$2 attempt=1 result inventory file hash
  shift 2
  local pending=("$@") remaining=()
  while :; do
    result=0
    if [ "$attempt" -gt 1 ]; then
      # A batch can partially succeed, or lose its final reply. Reuse only
      # completed assets with the exact local digest; never clobber them.
      inventory=$(gh release view "$tag" --repo "$repository" --json assets) || result=$?
      if [ "$result" -eq 0 ]; then
        remaining=()
        for file in "${pending[@]}"; do
          hash=$(php_darwin_sha256 "$file") || return 1
          if ! jq -e --arg name "${file##*/}" --arg digest "sha256:$hash" \
            'any(.assets[]; .name == $name and .state == "uploaded" and .digest == $digest)' \
            <<< "$inventory" >/dev/null; then
            remaining+=("$file")
          fi
        done
        [ "${#remaining[@]}" -gt 0 ] || return 0
        pending=("${remaining[@]}")
      fi
    fi
    if [ "$result" -eq 0 ]; then
      gh release upload "$tag" "${pending[@]}" --repo "$repository" && return 0
      result=$?
    fi
    [ "$attempt" -lt 3 ] || return "$result"
    printf 'Release upload failed; retry %s/3 after checking completed assets\n' "$((attempt + 1))" >&2
    sleep "$((1 << (attempt - 1)))"
    attempt=$((attempt + 1))
  done
}
