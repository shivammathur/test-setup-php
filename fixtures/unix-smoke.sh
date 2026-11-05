#!/usr/bin/env bash
set -eo pipefail
. fixtures/unix.sh
. fixtures/add_extensions.sh
mkdir -p artifacts
version=8.5
fail_fast=true
ini_file=("$(php -r 'echo php_ini_loaded_file();')")
ini_dir="${ini_file[0]%/*}"
scan_dir="$ini_dir/conf.d"
pecl_file="$scan_dir/99-pecl.ini"
ext_dir="$(php -r 'echo ini_get("extension_dir");')"
actual_pie="$(command -v pie)"
pie_call=0
pie() {
  pie_call=$((pie_call + 1))
  "$actual_pie" "$@" > "artifacts/pie-$pie_call.log" 2>&1
}
if ! pie_install phpstan_turbo phpstan/turbo:2.3.5 false; then
  cat artifacts/pie-*.log
  exit 1
fi
grep -Fq 'Pre-packaged binary found:' artifacts/pie-1.log
if pie_install apcu apcu/apcu:5.1.28 false; then
  echo 'A source-only package was accepted in binary-only mode'
  exit 1
fi
grep -Eq 'All download URL methods|all.*suppressed|suppressed.*all|suppressed' artifacts/pie-2.log
if ! pie_install apcu apcu/apcu:5.1.28 true; then
  cat artifacts/pie-*.log
  exit 1
fi
grep -Fq 'Build complete:' artifacts/pie-3.log
php --ri phpstan_turbo > artifacts/phpstan-turbo.txt
php --ri apcu > artifacts/apcu.txt
php -r 'exit(extension_loaded("phpstan_turbo") && phpversion("apcu") === "5.1.28" ? 0 : 1);'
cp "$ext_dir/phpstan_turbo.so" "$ext_dir/apcu.so" artifacts/
file artifacts/*.so
ldd artifacts/*.so
