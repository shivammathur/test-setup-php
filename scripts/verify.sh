#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$RUNNER_TEMP/evidence"
actual=$(shasum -a 256 "$(command -v php)" | awk '{print $1}')
expected=$(cat "$RUNNER_TEMP/evidence/expected-php.sha256")
[[ "$actual" = "$expected" ]]
printf '%s\n' "$actual" > "$RUNNER_TEMP/evidence/installed-php.sha256"
file -L "$(command -v php)" | tee "$RUNNER_TEMP/evidence/php-file.txt"
arch=$EXPECTED_ARCHITECTURE
[[ "$RUNNER_OS" != Linux || "$arch" != arm64 ]] || arch=aarch64
grep -E "${arch}|${arch/_/-}" "$RUNNER_TEMP/evidence/php-file.txt"
php -v | tee "$RUNNER_TEMP/evidence/php-version.txt"
php --ini | tee "$RUNNER_TEMP/evidence/php-ini.txt"
php -m | tee "$RUNNER_TEMP/evidence/php-modules.txt"
php scripts/runtime.php | tee "$RUNNER_TEMP/evidence/runtime.json"
phpize --version | tee "$RUNNER_TEMP/evidence/phpize.txt"
php-config --version | tee "$RUNNER_TEMP/evidence/php-config.txt"
php-cgi -v | tee "$RUNNER_TEMP/evidence/php-cgi.txt"
composer --version | tee "$RUNNER_TEMP/evidence/composer-version.txt"
composer show --platform | tee "$RUNNER_TEMP/evidence/composer-platform.txt"
# shellcheck disable=SC2016
ssl=$(php -r '$v = curl_version(); echo $v["ssl_version"];')
case "$ssl" in
  OpenSSL/*) backend=openssl ;;
  GnuTLS/*) backend=gnutls ;;
  *) echo "Unrecognized curl TLS backend: $ssl" >&2; exit 1 ;;
esac
grep -Eq "^lib-curl-${backend}[[:space:]]" "$RUNNER_TEMP/evidence/composer-platform.txt"
if grep -Eq '^lib-curl-[^[:space:]]*[()]' "$RUNNER_TEMP/evidence/composer-platform.txt"; then
  echo 'Invalid Composer curl platform package' >&2
  exit 1
fi
mkdir "$RUNNER_TEMP/composer-project"
(
  cd "$RUNNER_TEMP/composer-project"
  composer require --no-interaction --no-progress psr/log:1.1.4
  php -r 'require "vendor/autoload.php"; if (!interface_exists("Psr\\Log\\LoggerInterface")) { exit(1); }'
)
printf 'All setup-php runtime, artifact, extension and Composer checks passed.\n' | tee "$RUNNER_TEMP/evidence/result.txt"
