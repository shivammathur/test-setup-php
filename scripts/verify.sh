#!/usr/bin/env bash
set -euo pipefail
variant=$1
service_manager=$2
runner=$3
qa_root=$PWD
mkdir -p reports candidate
exec > >(tee reports/validation.log) 2>&1
unset ASAN_OPTIONS UBSAN_OPTIONS ZEND_DONT_UNLOAD_MODULES USE_ZEND_ALLOC LD_PRELOAD
export DEBIAN_FRONTEND=noninteractive
unit=php8.6-fpm
env_file=/etc/php/8.6/fpm/asan-envvars
probe=/tmp/asan-fpm-probe.php
asan_tar=$(find "$qa_root/packages/asan" -name '*.tar.zst' ! -name '*-dbgsym*')
test -f "$asan_tar"
sha256sum "$asan_tar" | tee reports/original-sha256.txt
tar -I zstd -tf "$asan_tar" > reports/original-manifest.txt
tar -I zstd -xOf "$asan_tar" ./usr/lib/systemd/system/php8.6-fpm.service > reports/original-unit.txt
if grep -Eq 'Environment(File)?=' reports/original-unit.txt || \
   grep -Eq '/(etc/default/|[^/]+\.service\.d/|fpm/asan-envvars)' reports/original-manifest.txt; then
  echo 'The original package unexpectedly already configures FPM.'
  exit 1
fi

if [ "$variant" = patched ]; then
  git -c safe.directory="$qa_root/builder" -C builder apply --check "$qa_root/fpm-runtime.patch"
  git -c safe.directory="$qa_root/builder" -C builder apply "$qa_root/fpm-runtime.patch"
  stage=$(mktemp -d)
  sudo tar -I zstd -xf "$asan_tar" -C "$stage" --no-same-owner
  sudo cp builder/config/fpm-asan.envvars "$stage/etc/php/8.6/fpm/asan-envvars"
  sed -e 's/PHP_VERSION/8.6/g' -e 's/NO_DOT/86/g' builder/config/php-fpm.service | \
    sudo tee "$stage/usr/lib/systemd/system/php8.6-fpm.service" >/dev/null
  sed 's/PHP_VERSION/8.6/g' builder/scripts/php-fpm.init | \
    sudo tee "$stage/etc/init.d/php8.6-fpm" >/dev/null
  sudo chmod 755 "$stage/etc/init.d/php8.6-fpm"
  sudo cp "$stage/etc/php/8.6/fpm/asan-envvars" reports/packaged-env.txt
  sudo cp "$stage/usr/lib/systemd/system/php8.6-fpm.service" reports/packaged-unit.txt
  sudo cp "$stage/etc/init.d/php8.6-fpm" reports/packaged-init.txt
  # Do not archive mktemp's private directory permissions as the install root.
  sudo chmod 755 "$stage"
  sudo tar -I 'zstd -T0 -3' -cf "$qa_root/candidate/$(basename "$asan_tar")" -C "$stage" .
  sudo rm -rf "$stage"
  asan_tar="$qa_root/candidate/$(basename "$asan_tar")"
  sha256sum "$asan_tar" | tee reports/patched-sha256.txt
  tar -I zstd -tf "$asan_tar" > reports/patched-manifest.txt

  # Exercise the same optional service hooks in a regular build too.
  regular_tar=$(find "$qa_root/packages/regular" -name '*.tar.zst' ! -name '*-dbgsym*')
  test -f "$regular_tar"
  stage=$(mktemp -d)
  sudo tar -I zstd -xf "$regular_tar" -C "$stage" --no-same-owner
  sudo cp reports/packaged-unit.txt "$stage/usr/lib/systemd/system/php8.6-fpm.service"
  sudo cp reports/packaged-init.txt "$stage/etc/init.d/php8.6-fpm"
  sudo chmod 755 "$stage" "$stage/etc/init.d/php8.6-fpm"
  test ! -e "$stage/etc/php/8.6/fpm/asan-envvars"
  sudo tar -I 'zstd -T0 -3' -cf "$qa_root/candidate/$(basename "$regular_tar")" -C "$stage" .
  sudo rm -rf "$stage"
  regular_tar="$qa_root/candidate/$(basename "$regular_tar")"
fi

collect_failure() {
  result=$?
  trap - EXIT
  if [ "$service_manager" = systemd ]; then
    sudo systemctl status "$unit" --no-pager 2>&1 | tee reports/final-status.txt || true
    sudo journalctl -u "$unit" --no-pager -n 150 2>&1 | tee reports/fpm-journal.txt || true
  fi
  sudo cp /var/log/php8.6-fpm.log reports/fpm.log 2>/dev/null || true
  sudo chmod -R a+rX reports candidate
  exit "$result"
}
trap collect_failure EXIT

install_package() {
  local archive=$1
  shift
  sudo service "$unit" stop >/dev/null 2>&1 || true
  sudo cp "$archive" /tmp/
  # Same artifact substitution used by php-builder's own workflow.
  sed '/download/d' builder/scripts/install.sh > /tmp/install-php-artifact.sh
  timeout 600 bash /tmp/install-php-artifact.sh 8.6 "$runner" release nts "$@"
}

cat > "$probe" <<'PHP'
<?php
header('Content-Type: application/json');
echo json_encode([
    'sapi' => PHP_SAPI,
    'version' => PHP_VERSION,
    'zend_memory_usage' => memory_get_usage(),
    'zend_memory_peak' => memory_get_peak_usage(),
    'environment' => array_combine(
        ['ASAN_OPTIONS', 'UBSAN_OPTIONS', 'ZEND_DONT_UNLOAD_MODULES', 'USE_ZEND_ALLOC', 'LD_PRELOAD'],
        array_map(fn($name) => getenv($name, true),
            ['ASAN_OPTIONS', 'UBSAN_OPTIONS', 'ZEND_DONT_UNLOAD_MODULES', 'USE_ZEND_ALLOC', 'LD_PRELOAD'])
    ),
]), "\n";
PHP
chmod 644 "$probe"

inspect_runtime() {
  local label=$1 expected=$2 pid
  if [ "$service_manager" = systemd ]; then
    sudo systemctl is-active "$unit"
    sudo systemctl show "$unit" -p MainPID -p Environment -p EnvironmentFiles | tee "reports/$label-systemd.txt"
    pid=$(sudo systemctl show "$unit" -p MainPID --value)
  else
    pid=$(sudo cat /run/php/php8.6-fpm.pid)
  fi
  test "$pid" -gt 1
  if [ "$expected" = configured ]; then
    sudo cmp builder/config/fpm-asan.envvars "$env_file"
  else
    test ! -e "$env_file"
  fi
  sudo env SCRIPT_FILENAME="$probe" REQUEST_METHOD=GET \
    cgi-fcgi -bind -connect /run/php/php8.6-fpm.sock | tee "reports/$label-response.txt"
  python3 - "$expected" "reports/$label-response.txt" "$label" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[2]).read_text().split('\n\n', 1)[1])
assert data['sapi'] == 'fpm-fcgi', data
assert data['version'].startswith('8.6.'), data
assert (data['zend_memory_usage'] == 0) == (sys.argv[1] == 'configured'), data
if sys.argv[3] == 'observed-environment':
    assert data['environment'] == {
        'ASAN_OPTIONS': 'detect_leaks=0',
        'UBSAN_OPTIONS': 'halt_on_error=1',
        'ZEND_DONT_UNLOAD_MODULES': '1',
        'USE_ZEND_ALLOC': '0',
        'LD_PRELOAD': False,
    }, data
print('Verified FPM request:', data)
PY
}

install_package "$asan_tar" asan > reports/install-asan.log 2>&1
if [ "$variant" = original ]; then
  inspect_runtime original missing
  echo 'CONFIRMED: the normal install starts FPM without all four sanitizer settings, with Zend allocation enabled.'
else
  inspect_runtime installed configured
  # FPM relocates and clears the initial environment when setting its process
  # title, so /proc/PID/environ cannot observe it. After verifying the untouched
  # install, temporarily retain the inherited worker environment for one probe.
  # This sets no sanitizer variables and is restored before the SAPI test.
  sudo cp /etc/php/8.6/fpm/pool.d/www.conf /tmp/fpm-qa-www.conf
  printf '\nclear_env = no\n' | sudo tee -a /etc/php/8.6/fpm/pool.d/www.conf >/dev/null
  sudo service "$unit" restart
  inspect_runtime observed-environment configured
  sudo cp /tmp/fpm-qa-www.conf /etc/php/8.6/fpm/pool.d/www.conf
  sudo service "$unit" restart
  inspect_runtime restarted configured
  # Exercise the patched upstream SAPI test with no caller sanitizer variables.
  PHP_VERSION=8.6 timeout 300 bash builder/scripts/test_sapi.sh | tee reports/sapi-test.txt
  test ! -e /etc/default/php-fpm8.6
  test ! -e /etc/systemd/system/php8.6-fpm.service.d/asan-env.conf
  inspect_runtime after-sapi configured
  # The normal installer clears the versioned configuration on replacement.
  test -f "$regular_tar"
  install_package "$regular_tar" > reports/install-regular.log 2>&1
  test ! -e "$env_file"
  inspect_runtime regular missing
  echo 'PASS: packaged defaults survive restart and SAPI switching; regular reinstall removes them.'
fi
