#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-policy-test.XXXXXX") || exit 1
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
prefix="$work_dir/prefix"
keg=Cellar/example/1.0
mkdir -p "$prefix/$keg/share/doc/pkg" "$prefix/$keg/share/man/man1" \
  "$prefix/$keg/share/info" "$prefix/$keg/lib" "$prefix/$keg/include" \
  "$prefix/share/man/man1" "$prefix/share/pear/doc" "$prefix/opt" \
  "$prefix/etc" "$prefix/var" || exit 1
for member in "$keg/share/doc/pkg/guide.txt" "$keg/share/doc/pkg/LICENSE.md" \
  "$keg/share/doc/pkg/NOTICE" "$keg/share/doc/pkg/blob.data" \
  "$keg/share/doc/pkg/runtime.txt" "$keg/share/man/man1/example.1" \
  "$keg/share/info/example.info" "$keg/lib/libexample.dylib" \
  "$keg/include/example.h" "$keg/INSTALL_RECEIPT.json" \
  share/pear/doc/runtime.txt etc/example.ini var/state; do
  printf 'fixture %s\n' "$member" > "$prefix/$member" || exit 1
done
ln -s share/doc/pkg/chain "$prefix/$keg/COPYING" || exit 1
ln -s blob.data "$prefix/$keg/share/doc/pkg/chain" || exit 1
ln -s ../Cellar/example/1.0 "$prefix/opt/example" || exit 1
ln -s ../opt/example/share/doc/pkg/runtime.txt "$prefix/etc/runtime-data" || exit 1
ln -s ../../../Cellar/example/1.0/share/man/man1/example.1 "$prefix/share/man/man1/example.1" || exit 1
ln -s /usr/local/opt/example/share/doc/pkg/blob.data "$prefix/$keg/LICENSE.absolute" || exit 1
ln -s cycle-b "$prefix/$keg/cycle-a" || exit 1
ln -s cycle-a "$prefix/$keg/cycle-b" || exit 1
find "$prefix" ! -type d -print | sed "s|^$prefix/||" | LC_ALL=C sort > "$work_dir/input" || exit 1
bash "$script_dir/../../build/filter-archive.sh" "$prefix" "$work_dir/input" "$work_dir/kept" /usr/local || exit 1
for member in "$keg/share/doc/pkg/guide.txt" "$keg/share/man/man1/example.1" \
  "$keg/share/info/example.info" share/man/man1/example.1; do
  if grep -Fxq "$member" "$work_dir/kept"; then
    printf 'Documentation was not filtered: %s\n' "$member" >&2
    exit 1
  fi
done
for member in "$keg/share/doc/pkg/LICENSE.md" "$keg/share/doc/pkg/NOTICE" \
  "$keg/share/doc/pkg/blob.data" "$keg/share/doc/pkg/chain" "$keg/COPYING" \
  "$keg/LICENSE.absolute" "$keg/share/doc/pkg/runtime.txt" \
  "$keg/lib/libexample.dylib" "$keg/include/example.h" "$keg/INSTALL_RECEIPT.json" \
  share/pear/doc/runtime.txt etc/example.ini var/state opt/example \
  etc/runtime-data "$keg/cycle-a" "$keg/cycle-b"; do
  grep -Fxq "$member" "$work_dir/kept" || {
    printf 'Required archive path was filtered: %s\n' "$member" >&2
    exit 1
  }
done
# A retained license-directory alias preserves its contents as well as its link.
ln -s share/doc/pkg "$prefix/$keg/LICENSES" || exit 1
printf '%s\n' "$keg/LICENSES" >> "$work_dir/input" || exit 1
bash "$script_dir/../../build/filter-archive.sh" "$prefix" "$work_dir/input" "$work_dir/kept-directory" /usr/local || exit 1
grep -Fxq "$keg/share/doc/pkg/guide.txt" "$work_dir/kept-directory" || exit 1
bash "$script_dir/../../build/filter-archive.sh" "$prefix" "$work_dir/kept-directory" "$work_dir/idempotent" /usr/local || exit 1
cmp -s "$work_dir/kept-directory" "$work_dir/idempotent" || exit 1
for invalid in ../escape /absolute Cellar/../escape Cellar/./escape; do
  printf '%s\n' "$invalid" > "$work_dir/invalid"
  if bash "$script_dir/../../build/filter-archive.sh" "$prefix" "$work_dir/invalid" "$work_dir/rejected" >/dev/null 2>&1; then
    printf 'Unsafe archive path accepted: %s\n' "$invalid" >&2
    exit 1
  fi
done
printf 'Documentation filtering, license preservation, and symlink closure validation passed\n'
