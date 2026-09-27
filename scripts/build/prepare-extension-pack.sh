#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"
[ "${GITHUB_ACTIONS:-}" = true ] || php_darwin_die 'extension builds require an Actions runner'
php_darwin_configure_homebrew_environment
mode=${1:-build}
case "$mode" in build|test) ;; *) php_darwin_die 'usage: prepare-extension-pack.sh build|test' ;; esac
formula=$(php_darwin_formula "${PHP_VERSION:?}" "${BUILD:?}" "${TS:?}")
tap=$(php_darwin_package_config tap)
tap_path=$(php_darwin_tap_repository_path "$tap")
# A build runner may retain a detached tap from an earlier job. The published
# PHP archive supplies its matching tap; every installed PHP keg stays in place.
if [ -d "$tap_path" ]; then HOMEBREW_DEVELOPER=1 brew untap "$tap"; fi
PHP_DARWIN_PREFER_MIRROR=true bash "$script_dir/../install.sh" "$PHP_VERSION" "$BUILD" "$TS"
# Source builds can load build dependencies such as bison@2.7 from this tap,
# beyond the installed PHP formula trusted by the normal cache installer.
if [ "$mode" = build ]; then brew trust "$tap"; fi
"$(brew --prefix)/opt/$formula/bin/php-config" --version
if [ "$(php_darwin_version_channel "$PHP_VERSION")" = nightly ]; then
  # Read the commit from the tap restored with this PHP, not the moving branch.
  php_src_commit=$(HOMEBREW_PHP_PATH="$tap_path" bash "$script_dir/php-src-commit.sh" "$PHP_VERSION")
  printf 'PHP_DARWIN_PHP_SRC_COMMIT=%s\n' "$php_src_commit" >> "${GITHUB_ENV:?}"
fi
[ "$mode" = build ] || exit 0
brew tap shivammathur/extensions
brew trust shivammathur/extensions
extension_tap=$(brew --repository shivammathur/extensions)
if [ "$(git -C "$extension_tap" rev-parse HEAD)" != "${HOMEBREW_EXTENSIONS_COMMIT:?}" ]; then
  if ! git -C "$extension_tap" cat-file -e "$HOMEBREW_EXTENSIONS_COMMIT^{commit}" 2>/dev/null; then
    git -C "$extension_tap" fetch --depth=1 origin "$HOMEBREW_EXTENSIONS_COMMIT"
  fi
  git -C "$extension_tap" checkout --detach "$HOMEBREW_EXTENSIONS_COMMIT"
fi
