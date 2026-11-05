#!/usr/bin/env bash
set -e
php --ri phpstan_turbo
php -d disable_classes=Phar fixtures/resolver.php "$GITHUB_WORKSPACE/setup-php"
if ! pie_install fastjson latest false; then
  echo 'FastJSON binary installation failed'
  exit 1
fi
php --ri fastjson
cp "$ext_dir/fastjson.so" artifacts/
if pie_install apcu latest false; then
  echo 'Source-only release unexpectedly installed in binary-only mode'
  exit 1
else
  result=$?
  [ "$result" = 2 ] || { echo "Expected source-required status 2, got $result"; exit 1; }
fi
if [ "$(uname -s)" = Darwin ]; then
  apcu_CONFIGURE_PREFIX_OPTS="CPPFLAGS=-I$(brew --prefix pcre2)/include"
fi
if ! pie_install apcu latest true; then
  echo 'The existing VCS builder failed to install the selected APCu release'
  exit 1
fi
php --ri apcu
cp "$ext_dir/apcu.so" artifacts/
php -r 'foreach (["phpstan_turbo", "fastjson", "apcu"] as $extension) { if (!extension_loaded($extension)) { exit(1); } }'
