#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence
{
  uname -m
  sw_vers
  command -v php || true
  php -v || true
  php --ini || true
  php -m || true
} > evidence/runtime.txt 2>&1
prefix=$(brew --prefix)
{
  readlink "$prefix/bin/php" || true
  brew list --formula --versions | awk '$1 ~ /^php(@|-|$)/'
} > evidence/homebrew-php.txt 2>&1
for file in "$RUNNER_TEMP"/php-darwin-e2e-* "$RUNNER_TEMP"/php-darwin-setup-install-seconds.txt; do
  [ ! -f "$file" ] || cp "$file" evidence/
done
for file in "$prefix"/var/php-darwin/php_"$PHP_VERSION"-*.json; do
  [ ! -f "$file" ] || cp "$file" evidence/
done
if [ -f "$RUNNER_TEMP/php-darwin-setup-install-seconds.txt" ]; then
  seconds=$(cat "$RUNNER_TEMP/php-darwin-setup-install-seconds.txt")
  printf 'Cache installer: **%ss** (required <10s).\n' "$seconds" >> "$GITHUB_STEP_SUMMARY"
else
  printf 'No completed php-darwin installer invocation was recorded.\n' >> "$GITHUB_STEP_SUMMARY"
fi
