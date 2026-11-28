#!/usr/bin/env bash
set -euo pipefail
docker run --rm \
  -v "$PWD/builder:/work" -w /work \
  -e GITHUB_WORKSPACE=/work -e PHP_VERSION=8.0 -e TS=nts -e BUILDS=release \
  -e NIGHTLY=false -e CONTAINER=ubuntu:22.04 \
  ubuntu:22.04 bash -euo pipefail -c '
    test "$(bash scripts/get-source.sh)" = packages
    bash scripts/install-requirements.sh
    bash scripts/install-zstd.sh
    bash scripts/configure-filesystem-snapshot.sh
    bash scripts/install-php.sh
    php8.0 --version
    dpkg-query -W php8.0-cli libphp8.0-embed
    bash scripts/package-php.sh
  '
