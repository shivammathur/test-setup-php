#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} = true && $EUID -eq 0 ]] || exit 1
awk '/^# Variables$/ {exit} {print}' "${ACTION_ROOT:?}/src/scripts/linux.sh" > /tmp/linux-functions.sh
sed -n '/^debconf_fix=/p; /^apt_install=/p' "${ACTION_ROOT:?}/src/scripts/linux.sh" >> /tmp/linux-functions.sh
for revision in 1 2 3; do
  pkg=/tmp/package-$revision
  mkdir -p "$pkg/DEBIAN" "$pkg/etc" "$pkg/usr/bin"
  cat > "$pkg/DEBIAN/control" <<CONTROL
Package: setup-php-cleanup-check
Version: $revision.0
Architecture: all
Maintainer: Test <test@example.invalid>
Description: Disposable setup-php configuration regression check
CONTROL
  echo /etc/setup-php-cleanup-check.conf > "$pkg/DEBIAN/conffiles"
  echo "version-$revision" > "$pkg/etc/setup-php-cleanup-check.conf"
  printf '#!/bin/sh\necho version-%s\n' "$revision" > "$pkg/usr/bin/setup-php-cleanup-check"
  chmod +x "$pkg/usr/bin/setup-php-cleanup-check"
  dpkg-deb -Zgzip --build "$pkg" "/tmp/package-$revision.deb" >/dev/null
done
for installer in fallback apt-fast; do
  for existing_marker in false true; do
    rm -f /usr/bin/apt-fast /etc/dpkg/dpkg.cfg.d/force-confnew
    if [[ "$installer" = apt-fast ]]; then
      cp "${APT_FAST_SOURCE:?}" /usr/bin/apt-fast
      chmod +x /usr/bin/apt-fast
    fi
    if "$existing_marker"; then printf 'force-confnew\n# existing-marker\n' > /etc/dpkg/dpkg.cfg.d/force-confnew; fi
    export existing_marker
    bash -euo pipefail <<'CASE'
source /tmp/linux-functions.sh
sudo() { env "$@" >> /tmp/apt-integration.log 2>&1; }
update_lists() { echo 'Unexpected retry in configuration test' >&2; return 98; }
check_marker() {
  if "$existing_marker"; then
    [[ $(cat /etc/dpkg/dpkg.cfg.d/force-confnew) = $'force-confnew\n# existing-marker' ]]
  else
    [[ ! -e /etc/dpkg/dpkg.cfg.d/force-confnew ]]
  fi
}
link_apt_fast
before=$(trap -p EXIT)
install_packages /tmp/package-1.deb
[[ $(cat /etc/setup-php-cleanup-check.conf) = version-1 ]]
echo locally-modified > /etc/setup-php-cleanup-check.conf
install_packages /tmp/package-2.deb
[[ $(cat /etc/setup-php-cleanup-check.conf) = version-2 ]]
check_marker
echo locally-modified-again > /etc/setup-php-cleanup-check.conf
dpkg --unpack /tmp/package-3.deb >> /tmp/apt-integration.log 2>&1
fix_broken_packages
[[ $(cat /etc/setup-php-cleanup-check.conf) = version-3 ]]
[[ $(setup-php-cleanup-check) = version-3 ]]
(install_packages /tmp/package-3.deb)
install_packages /tmp/package-3.deb
[[ $(trap -p EXIT) = "$before" ]]
[[ -x /usr/bin/apt-fast ]]
check_marker
CASE
    if [[ "$installer" = fallback ]]; then
      [[ ! -e /usr/bin/apt-fast && ! -L /usr/bin/apt-fast ]]
    else
      cmp /usr/bin/apt-fast "${APT_FAST_SOURCE:?}"
    fi
    dpkg-query -W -f='${Package} ${Version} ${Status}\n' setup-php-cleanup-check
    dpkg --purge setup-php-cleanup-check >> /tmp/apt-integration.log 2>&1
    printf 'PASS installer=%s existing-marker=%s: conffile upgrade, repair, repeated/nested install, package artifact, traps and cleanup\n' "$installer" "$existing_marker"
  done
done
