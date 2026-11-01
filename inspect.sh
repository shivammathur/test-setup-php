#!/usr/bin/env bash
set -euo pipefail
expected=$1
phase=$2
evidence="evidence/$phase"
mkdir -p "$evidence"
php -v | tee "$evidence/php-version.txt"
php --ri ev | tee "$evidence/ev-info.txt"
php smoke.php "$expected" | tee "$evidence/smoke.txt"
ext_dir=$(php-config --extension-dir)
test -s "$ext_dir/ev.so"
test -s "$ext_dir/ev-$expected"
cmp "$ext_dir/ev.so" "$ext_dir/ev-$expected"
cp "$ext_dir/ev.so" "$evidence/ev.so"
file "$evidence/ev.so" | tee "$evidence/file.txt"
if [ "$(uname -s)" = Linux ]; then
  readelf -h -d "$evidence/ev.so" > "$evidence/readelf.txt"
  ldd "$evidence/ev.so" | tee "$evidence/dependencies.txt"
  if grep -q 'not found' "$evidence/dependencies.txt"; then exit 1; fi
else
  otool -L "$evidence/ev.so" | tee "$evidence/dependencies.txt"
fi
shasum -a 256 "$evidence/ev.so" | tee "$evidence/SHA256SUMS"
php_opts=(-n)
if ! php -n -r 'exit(extension_loaded("sockets") ? 0 : 1);'; then
  test -s "$ext_dir/sockets.so"
  php_opts+=(-d "extension=$ext_dir/sockets.so")
fi
php "${php_opts[@]}" -d "extension=$PWD/$evidence/ev.so" smoke.php "$expected" | tee "$evidence/smoke-isolated.txt"
