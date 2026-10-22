#!/usr/bin/env bash
set -euo pipefail
mkdir -p artifacts/fixtures
cd fixtures
phpize
./configure --enable-pecl_fixture
for fixture_version in 1.5.0 2.0.1 1.5.0-beta1; do
  printf '#define FIXTURE_VERSION "%s"\n' "$fixture_version" > fixture_version.h
  make clean
  make -j2
  cp modules/pecl_fixture.so "../artifacts/fixtures/$fixture_version.so"
  php -n -d "extension=$PWD/modules/pecl_fixture.so" -r 'if (phpversion("pecl_fixture") !== $argv[1]) { exit(1); } echo phpversion("pecl_fixture"), PHP_EOL;' -- "$fixture_version"
done
