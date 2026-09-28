#!/usr/bin/env bash
set +e
cat /etc/os-release
uname -m
php -v
php --ri gd
php --ri imagick
php-config --configure-options
dpkg-query -W -f='${binary:Package} ${Version} ${db:Status-Abbrev}\n' 'libheif*' 'libaom*' '*magick*' 'libavif*'
for extension in gd imagick; do
  ldd "$(php-config --extension-dir)/$extension.so"
done
find /usr/lib -path '*libheif*' -type f 2>/dev/null
exit 0
