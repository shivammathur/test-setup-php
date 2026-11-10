#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} = true && $EUID -eq 0 ]] || exit 1
for variant in baseline fixed; do
  source_root=$BASELINE_ROOT
  [[ "$variant" = baseline ]] || source_root=$ACTION_ROOT
  awk '/^# Variables$/ {exit} {print}' "$source_root/src/scripts/linux.sh" > "/tmp/$variant-functions.sh"
  sed -n '/^debconf_fix=/p; /^apt_install=/p' "$source_root/src/scripts/linux.sh" >> "/tmp/$variant-functions.sh"
done
apt-config dump > "$EVIDENCE/apt-config.txt"
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
    comparison_dir="$EVIDENCE/conffile-$installer-$existing_marker"
    mkdir -p "$comparison_dir"
    export existing_marker comparison_dir
    for variant in baseline fixed; do
      export variant
      rm -f /usr/bin/apt-fast /etc/dpkg/dpkg.cfg.d/force-confnew
      if [[ "$installer" = apt-fast ]]; then
        cp "$APT_FAST_SOURCE" /usr/bin/apt-fast
        chmod +x /usr/bin/apt-fast
      fi
      if "$existing_marker"; then printf 'force-confnew\n# existing-marker\n' > /etc/dpkg/dpkg.cfg.d/force-confnew; fi
      bash -euo pipefail <<'CASE'
source "/tmp/$variant-functions.sh"
sudo() { env "$@" >> /tmp/apt-integration.log 2>&1; }
update_lists() { echo 'Unexpected retry in configuration test' >&2; return 98; }
if [[ "$variant" = baseline ]]; then link_apt_fast; else set_apt_install; fi
before=$(trap -p EXIT)
install_packages /tmp/package-1.deb
[[ $(cat /etc/setup-php-cleanup-check.conf) = version-1 ]]
echo locally-modified > /etc/setup-php-cleanup-check.conf
install_packages /tmp/package-2.deb
cp /etc/setup-php-cleanup-check.conf "$comparison_dir/$variant-install.conf"
echo locally-modified-again > /etc/setup-php-cleanup-check.conf
dpkg --unpack /tmp/package-3.deb >> /tmp/apt-integration.log 2>&1
fix_broken_packages
cp /etc/setup-php-cleanup-check.conf "$comparison_dir/$variant-repair.conf"
[[ $(setup-php-cleanup-check) = version-3 ]]
(install_packages /tmp/package-3.deb)
install_packages /tmp/package-3.deb
if [[ "$variant" = fixed ]]; then [[ $(trap -p EXIT) = "$before" ]]; fi
CASE
      if [[ "$variant" = fixed && "$installer" = fallback ]]; then
        [[ ! -e /usr/bin/apt-fast && ! -L /usr/bin/apt-fast ]]
      elif [[ "$installer" = apt-fast ]]; then
        cmp /usr/bin/apt-fast "$APT_FAST_SOURCE"
      fi
      if "$existing_marker"; then
        [[ $(cat /etc/dpkg/dpkg.cfg.d/force-confnew) = $'force-confnew\n# existing-marker' ]]
      else
        [[ ! -e /etc/dpkg/dpkg.cfg.d/force-confnew ]]
      fi
      dpkg-query -W -f='${Package} ${Version} ${Status}\n' setup-php-cleanup-check
      dpkg --purge setup-php-cleanup-check >> /tmp/apt-integration.log 2>&1
    done
    cmp "$comparison_dir/baseline-install.conf" "$comparison_dir/fixed-install.conf"
    cmp "$comparison_dir/baseline-repair.conf" "$comparison_dir/fixed-repair.conf"
    printf 'PASS installer=%s existing-marker=%s: install and repair match the released baseline; repeated/nested calls, package artifact and cleanup passed\n' "$installer" "$existing_marker"
  done
done
