#!/usr/bin/env bash
repo=$1
case_dir=$2
scenario=$3
php_binary=$4
fixtures=$5
iterations=$6
count_calls=$7
source "$repo/src/scripts/unix.sh"
source "$repo/src/scripts/extensions/add_extensions.sh"
version="pecl-benchmark-$$"
semver=benchmark
fail_fast=false
ext_dir="$case_dir/extensions"
mkdir -p "$ext_dir" "$case_dir/conf.d"
export PHP_INI_SCAN_DIR="$case_dir/conf.d"
printf 'display_errors=Off\ndisplay_startup_errors=Off\n' > "$case_dir/php.ini"
php() {
  [ "$count_calls" = true ] && printf 'php\n' >> "$case_dir/php-calls.txt"
  "$php_binary" -c "$case_dir/php.ini" "$@"
}
sudo() { "$@"; }
enable_extension() {
  if [ -e "$ext_dir/$1.so" ]; then
    printf 'extension="%s/%s.so"\n' "$ext_dir" "$1" > "$case_dir/conf.d/fixture.ini"
  fi
}
pecl_install() {
  [ "$scenario" = fallback-mismatch ] && return 1
  cp "$fixtures/1.5.0.so" "$ext_dir/pecl_fixture.so"
  enable_extension pecl_fixture extension
}
add_extension_helper() {
  cp "$fixtures/2.0.1.so" "$ext_dir/pecl_fixture.so"
  enable_extension pecl_fixture extension
}
trap 'rm -f "/tmp/php${version}_extensions"' EXIT
requested=1.5.0
[ "$scenario" = unpinned ] && requested=
for ((i=0; i<iterations; i++)); do
  rm -f "$ext_dir/pecl_fixture.so" "$ext_dir/pecl_fixture-1.5.0" "$case_dir/conf.d/fixture.ini" "/tmp/php${version}_extensions"
  case "$scenario" in
    enabled)
      cp "$fixtures/1.5.0.so" "$ext_dir/pecl_fixture.so"
      printf 'pecl_fixture\n' > "/tmp/php${version}_extensions"
      ;;
    cached) cp "$fixtures/1.5.0.so" "$ext_dir/pecl_fixture-1.5.0" ;;
  esac
  add_pecl_extension pecl_fixture "$requested" extension >/dev/null
done
