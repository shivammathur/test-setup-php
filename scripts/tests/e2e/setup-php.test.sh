#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

version=${PHP_VERSION:-${1:-}}
php_darwin_validate_version "$version"
channel=$(php_darwin_version_channel "$version") || exit 1
arch=$(php_darwin_normalize_arch "$(uname -m)") || exit 1
asset=$(php_darwin_asset "$version" release nts "$arch") || exit 1
brew_prefix=$(brew --prefix) || exit 1
bash "$script_dir/../helpers/check-preserved-homebrew.sh" check "$brew_prefix" \
  "${RUNNER_TEMP:?}/php-darwin-e2e-preserved.json" \
  "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons || \
  php_darwin_die 'end-to-end installation changed existing PHP or its services'
formula=$(php_darwin_formula "$version" release nts) || exit 1

actual_semver=$(php-config --version) || php_darwin_die 'php-config could not report its version'
[ "${actual_semver%.*}" = "$version" ] || php_darwin_die "PHP $version is not active"

if [ "${PHP_DARWIN_REQUIRE_PACKS:-false}" = true ]; then
  php -r 'foreach (["imagick", "mongodb", "igbinary", "msgpack", "memcached"] as $name) {
    if (!extension_loaded($name)) { fwrite(STDERR, "Missing cached module: $name\n"); exit(1); }
  }' || php_darwin_die 'optional extension packs were not enabled'
  extension_dir=$(php-config --extension-dir) || exit 1
  for extension in imagick mongodb memcached; do
    module="$extension_dir/$extension.so"
    [ -L "$module" ] || php_darwin_die "$extension did not use its separate cache"
    case "$(readlink "$module")" in
      "$brew_prefix/var/php-darwin/extensions/"*/modules/"$extension.so") ;;
      *) php_darwin_die "$extension module is outside the private cache" ;;
    esac
  done
fi

if [ "${PHP_DARWIN_REQUIRE_XDEBUG:-false}" = true ]; then
  # shellcheck disable=SC2016
  php -r '
    if (!extension_loaded("xdebug")) {
      fwrite(STDERR, "Xdebug is not loaded\n");
      exit(1);
    }
  ' || php_darwin_die 'cache-extensions integration failed'
fi
if [ "${PHP_DARWIN_REQUIRE_PCOV:-false}" = true ]; then
  # shellcheck disable=SC2016
  php -r '
    if (!extension_loaded("pcov")) {
      fwrite(STDERR, "PCOV is not loaded\n");
      exit(1);
    }
  ' || php_darwin_die 'PCOV cache integration failed'
fi
# Defaults apply only to new configuration. Existing enabled extensions belong
# to the runner and are intentionally preserved by a direct cache installation.
if [ "${PHP_DARWIN_REQUIRE_XDEBUG:-false}" != true ] && \
  [ "${PHP_DARWIN_REQUIRE_PCOV:-false}" != true ] && \
  [ "$(cat "${RUNNER_TEMP:?}/php-darwin-e2e-existing-config.txt")" = false ]; then
  while IFS= read -r extension; do
    php -r "if (extension_loaded('$extension')) { exit(1); }" || \
      php_darwin_die "$extension is enabled by default after a direct cache install"
  done < <(bash "$script_dir/../../build/cached-extensions.sh" "$version")
fi

tap=$(php_darwin_package_config tap) || php_darwin_die 'could not read the Homebrew tap configuration'
trust_json=$(brew trust --json=v1) || php_darwin_die 'could not read Homebrew trust state'
if ! php_darwin_tap_trusted "$tap" "$trust_json" && \
  ! php_darwin_formula_trusted "$tap/$formula" "$trust_json"; then
  php_darwin_die "Homebrew does not trust the installed PHP $version formula"
fi

if [ "${PHP_DARWIN_REQUIRE_CACHE:-false}" = true ]; then
  started_at=${PHP_DARWIN_E2E_STARTED_AT:-${RUNNER_TEMP:?}/php-darwin-e2e-started-at.txt}
  installed_info=${RUNNER_TEMP:?}/php-darwin-e2e-installed-formulae.json
  source_built_formulae=${RUNNER_TEMP:?}/php-darwin-e2e-source-built-formulae.txt
  pecl_packages=${RUNNER_TEMP:?}/php-darwin-e2e-pecl-packages.txt
  release_manifest=${RUNNER_TEMP:?}/php-darwin-e2e-release-manifest.json
  tap_path=$(brew --repository "$tap") || php_darwin_die "could not resolve the installed $tap repository"
  snapshot_commit=$(git -C "$tap_path" config --get php-darwin.snapshot-commit 2>/dev/null) || \
    php_darwin_die 'setup-php did not install a php-darwin tap snapshot'
  tap_commit=$(git -C "$tap_path" rev-parse HEAD) || \
    php_darwin_die 'could not resolve the installed php-darwin tap snapshot'

  [[ "$snapshot_commit" =~ ^[0-9a-f]{40}$ ]] && [ "$snapshot_commit" = "$tap_commit" ] || \
    php_darwin_die 'the installed Homebrew tap is not the php-darwin cache snapshot'
  [[ "$(cat "$started_at")" =~ ^[0-9]+$ ]] || php_darwin_die 'the E2E start time is invalid'
  release_repository=$(php_darwin_package_config release_repository) || \
    php_darwin_die 'could not read the release repository configuration'
  manifest_status=$(php_darwin_fetch_release_manifest "$release_repository" "$version" "$release_manifest") || \
    php_darwin_die 'could not request the published release manifest'
  [ "$manifest_status" = 200 ] || php_darwin_die "could not fetch the published release manifest (HTTP $manifest_status)"
  manifest_values=$(php_darwin_validate_release_manifest "$release_manifest" "$version" "$channel" "$asset") || \
    php_darwin_die 'the published release manifest does not match the E2E cache'
  IFS=$'\t' read -r _ manifest_commit _ expected_semver _ _ _ <<< "$manifest_values" || \
    php_darwin_die 'could not read the published release manifest'
  [ "$tap_commit" = "$manifest_commit" ] || \
    php_darwin_die 'the installed tap snapshot does not match the published cache'
  actual_semver=$(php-config --version) || php_darwin_die 'PHP could not report its version'
  expected_runtime_semver=$expected_semver
  [ "$channel" != nightly ] || expected_runtime_semver="$expected_semver-dev"
  [ "$actual_semver" = "$expected_runtime_semver" ] || \
    php_darwin_die "setup-php used PHP $actual_semver instead of cached PHP $expected_runtime_semver"

  brew info --installed --json=v2 > "$installed_info" || \
    php_darwin_die 'could not inspect installed Homebrew formulae after setup-php'
  jq -r --argjson started_at "$(cat "$started_at")" '
    .formulae[] | .name as $name | .installed[] |
    select((.time // 0) >= $started_at and .poured_from_bottle != true) | $name
  ' "$installed_info" > "$source_built_formulae" || \
    php_darwin_die 'could not inspect Homebrew installation receipts for source builds'
  [ ! -s "$source_built_formulae" ] || \
    php_darwin_die "setup-php built formulae from source outside the cache build: $(tr '\n' ' ' < "$source_built_formulae")"

  pecl list > "$pecl_packages" || php_darwin_die 'PECL could not list installed packages'
  while IFS= read -r cached_extension; do
    [ -n "$cached_extension" ] || continue
    before_package=$(awk -v extension="$cached_extension" \
      'tolower($1) == tolower(extension) { print tolower($1), $2, $3 }' \
      "${RUNNER_TEMP:?}/php-darwin-e2e-pecl-before.txt") || exit 1
    after_package=$(awk -v extension="$cached_extension" \
      'tolower($1) == tolower(extension) { print tolower($1), $2, $3 }' "$pecl_packages") || exit 1
    [ -z "$after_package" ] || [ "$after_package" = "$before_package" ] || \
      php_darwin_die "setup-php rebuilt cached $cached_extension with PECL"
  done < <(bash "$script_dir/../../build/cached-extensions.sh" "$version")
fi

if [ "${PHP_DARWIN_REQUIRE_INSTALL_TIMING:-false}" = true ]; then
  elapsed=$(cat "${RUNNER_TEMP:?}/php-darwin-setup-install-seconds.txt") || \
    php_darwin_die 'setup-php did not record cache installer timing'
  [[ "$elapsed" =~ ^[0-9]+$ ]] || \
    php_darwin_die "invalid setup-php cache installation timing: $elapsed"
  printf 'Setup-php cache installation completed in %ss\n' "$elapsed"
fi

printf 'Verified php-darwin cache installation for PHP %s' "$version"
[ "${PHP_DARWIN_REQUIRE_XDEBUG:-false}" != true ] || printf ' with cache-extensions'
printf '\n'
