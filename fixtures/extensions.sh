#!/usr/bin/env bash
set -e
src="$GITHUB_WORKSPACE/setup-php/src"
source "$src/scripts/unix.sh"
source "$src/scripts/extensions/add_extensions.sh"
version=$(php -r 'echo PHP_MAJOR_VERSION,".",PHP_MINOR_VERSION;')
ext_dir=$(php -r 'echo ini_get("extension_dir");')
pecl_file=$(php -r 'echo php_ini_loaded_file();')
ini_dir=$(dirname "$pecl_file")
runner=github-hosted
php fixtures/resolver-check.php "$GITHUB_WORKSPACE/setup-php" "$(command -v composer)"
pie_install fastjson latest false
php --ri fastjson
php -r 'if (!extension_loaded("fastjson") || !extension_loaded("phpstan_turbo")) { exit(1); }'
cp "$ext_dir/fastjson.so" artifacts/
if pie_install apcu latest false; then
  echo 'Expected source-only APCu release to be rejected by binary-only mode'
  exit 1
fi
