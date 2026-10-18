#!/usr/bin/env bash
set -euo pipefail

test -s reports/install.log
grep -q 'fix_packages' reports/install.log
php -v | tee reports/php.txt
php-config --version | tee -a reports/php.txt
phpize -v | tee -a reports/php.txt
php -r 'exit(PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION === getenv("PHP_VERSION") ? 0 : 1);'
php-fpm -t
systemctl is-active php"$PHP_VERSION"-fpm
PHP_VERSION="$PHP_VERSION" bash cache/scripts/test-optional-extensions.sh >reports/extensions.log 2>&1

bash cache/scripts/check-test-packages.sh "$PHP_VERSION" "$RUNNER_OS" success success
grep -qx 'broken=false' "reports/$PHP_VERSION-$RUNNER_OS.env"
apt-get -s install jq > reports/downstream-apt.log
sha256sum /tmp/php_*.tar.zst > reports/archive.sha256
tar -I zstd -tf /tmp/php_*.tar.zst > reports/archive-files.txt

mkdir extension-build
cd extension-build
cat > config.m4 <<'EOF'
PHP_ARG_ENABLE(install_smoke, whether to enable install_smoke, [ --enable-install-smoke Enable install_smoke])
if test "$PHP_INSTALL_SMOKE" != "no"; then
  PHP_NEW_EXTENSION(install_smoke, install_smoke.c, $ext_shared)
fi
EOF
cat > install_smoke.c <<'EOF'
#ifdef HAVE_CONFIG_H
#include "config.h"
#endif
#include "php.h"
zend_module_entry install_smoke_module_entry = {
  STANDARD_MODULE_HEADER, "install_smoke", NULL, NULL, NULL, NULL, NULL, NULL,
  "0.1", STANDARD_MODULE_PROPERTIES
};
#ifdef COMPILE_DL_INSTALL_SMOKE
ZEND_GET_MODULE(install_smoke)
#endif
EOF
{
  phpize
  ./configure --enable-install-smoke --with-php-config="$(command -v php-config)"
  make -j2
  php -d "extension=$PWD/modules/install_smoke.so" -r 'exit(extension_loaded("install_smoke") ? 0 : 1);'
} > ../reports/extension-build.log 2>&1
cp modules/install_smoke.so ../reports/
