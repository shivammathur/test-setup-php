#!/usr/bin/env bash
set +e
cat /etc/os-release
printf '\nInstalled packages\n'
dpkg-query -W -f='${binary:Package} ${Version} ${db:Status-Abbrev}\n' 'libheif*' 'libaom*' '*magick*'
printf '\nPackage dependencies\n'
apt-cache depends libheif1 libheif-dev libheif-plugin-aomenc
printf '\nPlugin files\n'
find /usr/lib -path '*libheif*' -type f 2>/dev/null
printf '\nPHP / Imagick\n'
php -v
php --ri imagick
if command -v php-config >/dev/null; then ldd "$(php-config --extension-dir)/imagick.so"; fi
exit 0
