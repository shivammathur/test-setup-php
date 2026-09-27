#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

versions=$(php_darwin_nightly_versions) || exit 1
repository=${GITHUB_REPOSITORY:-$(php_darwin_package_config release_repository)}
ref=${GITHUB_REF_NAME:-main}

while IFS= read -r version; do
  gh workflow run cache-nightly.yml --repo "$repository" --ref "$ref" \
    -f "php-version=$version" || php_darwin_die "could not dispatch the PHP $version nightly cache"
done <<< "$versions"
