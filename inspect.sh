#!/usr/bin/env bash
# PHP snippets intentionally contain literal PHP variables.
# shellcheck disable=SC2016
set -euo pipefail
extension=${EXTENSION:?}
expected=$EXPECTED_VERSION
mkdir -p evidence
php -v | tee evidence/php-version.txt
php --ri "$extension" | tee evidence/extension-info.txt
php smoke.php | tee evidence/smoke.txt
ext_dir=$(php-config --extension-dir)
test -s "$ext_dir/$extension.so"
test -s "$ext_dir/$extension-$expected"
cmp "$ext_dir/$extension.so" "$ext_dir/$extension-$expected"
cp "$ext_dir/$extension.so" "evidence/$extension.so"
file "evidence/$extension.so" | tee evidence/file.txt
if [ "$(uname -s)" = Linux ]; then
  readelf -h -d "evidence/$extension.so" > evidence/readelf.txt
  ldd "evidence/$extension.so" | tee evidence/dependencies.txt
  if grep -q 'not found' evidence/dependencies.txt; then exit 1; fi
else
  otool -L "evidence/$extension.so" | tee evidence/dependencies.txt
fi
shasum -a 256 "evidence/$extension.so" | tee evidence/SHA256SUMS
php_opts=(-n)
while IFS= read -r dependency; do
  if ! php -n -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$dependency"; then
    test -s "$ext_dir/$dependency.so"
    php_opts+=(-d "extension=$ext_dir/$dependency.so")
  fi
done < <(php -r '$extension = new ReflectionExtension($argv[1]); foreach ($extension->getDependencies() as $name => $type) { if (extension_loaded($name)) { echo $name, PHP_EOL; } }' "$extension")
php "${php_opts[@]}" -d "extension=$PWD/evidence/$extension.so" smoke.php | tee evidence/smoke-isolated.txt
if [ "$extension" = vld ]; then
  php -d opcache.enable_cli=0 opcode.php | tee evidence/executed.txt
  grep -qx 'EXECUTED-42' evidence/executed.txt
  php "${php_opts[@]}" -d "extension=$PWD/evidence/vld.so" -d vld.active=1 -d vld.execute=0 -d vld.dump_paths=0 opcode.php > evidence/suppressed-stdout.txt 2> evidence/opcodes.txt
  grep -qi 'beta_probe' evidence/opcodes.txt
  grep -Eq '[[:space:]]ADD[[:space:]]' evidence/opcodes.txt
  grep -Eq '[[:space:]]RETURN[[:space:]]' evidence/opcodes.txt
  if grep -qx 'EXECUTED-42' evidence/suppressed-stdout.txt; then exit 1; fi
  printf 'VLD disassembly and execution suppression passed.\n' | tee evidence/functionality.txt
fi
