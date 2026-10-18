#!/usr/bin/env bash
set -euo pipefail
for tool in php php-config phpize phpdbg php-cgi phar phar.phar; do
  sudo update-alternatives --set "$tool" "/usr/bin/$tool$PHP_VERSION"
done
sudo update-alternatives --set php-fpm "/usr/sbin/php-fpm$PHP_VERSION"
