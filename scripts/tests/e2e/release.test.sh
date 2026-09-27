#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

version=${PHP_VERSION:-${1:-}}
php_darwin_validate_version "$version"
release_repository=$(php_darwin_package_config release_repository) || \
  php_darwin_die 'could not read the release repository configuration'
tmp_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-e2e.XXXXXX") || \
  php_darwin_die 'could not create the installer test directory'
installer="$tmp_dir/install.sh"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

started=$SECONDS
if [ -n "${PHP_DARWIN_TEST_INSTALLER:-}" ]; then
  cp "$PHP_DARWIN_TEST_INSTALLER" "$installer" || exit 1
else
mirror=$(php_darwin_release_mirror "$release_repository" "$version") || exit 1
urls=("https://github.com/$release_repository/releases/download/php-$version/install.sh")
if [ -n "$mirror" ]; then
  if [ "${PHP_DARWIN_PREFER_MIRROR:-false}" = true ]; then
    urls=("$mirror/install.sh" "${urls[@]}")
  else
    urls+=("$mirror/install.sh")
  fi
fi
status=000
for url in "${urls[@]}"; do
  status=$(php_darwin_request_release "$url" "$installer") || status=000
  [ "$status" != 200 ] || break
done
[ "$status" = 200 ] || php_darwin_die "could not download the PHP $version release installer"
fi
BASH_ENV="$script_dir/../helpers/trace-install-phases.sh" bash "$installer" "$version" release nts || \
  php_darwin_die "the PHP $version release installer failed"
elapsed=$((SECONDS - started))
printf 'Published cache download and installation completed in %ss\n' "$elapsed"
