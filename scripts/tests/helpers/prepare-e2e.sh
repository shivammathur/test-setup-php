#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

[ "${GITHUB_ACTIONS:-}" = true ] || \
  php_darwin_die 'prepare-e2e.sh may only modify a GitHub Actions runner'

brew_prefix=$(brew --prefix) || php_darwin_die 'could not resolve the Homebrew prefix'
started_at=${PHP_DARWIN_E2E_STARTED_AT:-${RUNNER_TEMP:?}/php-darwin-e2e-started-at.txt}
tap=$(php_darwin_package_config tap) || php_darwin_die 'could not read the Homebrew tap configuration'
preserved_homebrew="${RUNNER_TEMP:?}/php-darwin-e2e-preserved.json"
config_id=$(php_darwin_config_id "${PHP_VERSION:?}" release nts) || exit 1
if [ -d "$brew_prefix/etc/php/$config_id" ]; then
  printf 'true\n' > "${RUNNER_TEMP:?}/php-darwin-e2e-existing-config.txt"
else
  printf 'false\n' > "${RUNNER_TEMP:?}/php-darwin-e2e-existing-config.txt"
fi
php_darwin_configure_homebrew_environment
bash "$script_dir/check-preserved-homebrew.sh" snapshot "$brew_prefix" "$preserved_homebrew" \
  "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons || \
  php_darwin_die 'could not record existing PHP and services'
# A prior job may leave a detached tap. The archive supplies its matching tap;
# existing PHP kegs, PECL modules, configuration, and service definitions stay.
HOMEBREW_DEVELOPER=1 brew untap "$tap" >/dev/null 2>&1 || true
bash "$script_dir/check-preserved-homebrew.sh" check "$brew_prefix" "$preserved_homebrew" \
  "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons || \
  php_darwin_die 'E2E preparation changed existing PHP or its services'
pecl_before="${RUNNER_TEMP:?}/php-darwin-e2e-pecl-before.txt"
: > "$pecl_before"
if command -v pecl >/dev/null 2>&1; then
  pecl list > "$pecl_before" 2>/dev/null || : > "$pecl_before"
fi

date +%s > "$started_at" || php_darwin_die 'could not record the E2E start time'
printf 'Prepared cache validation with existing PHP and services preserved\n'
