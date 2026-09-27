#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

php_darwin_configure_homebrew_environment

required_tap=$(php_darwin_package_config tap) || exit 1
installed_taps=$(brew tap) || php_darwin_die 'could not list installed Homebrew taps'
unused_taps=()
untap_log=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-untap.XXXXXX") || \
  php_darwin_die 'could not create the Homebrew untap log'
trap 'rm -f "$untap_log"' EXIT

while IFS= read -r installed_tap; do
  [ -n "$installed_tap" ] || continue
  case "$installed_tap" in
    homebrew/core|"$required_tap") ;;
    *) unused_taps+=("$installed_tap") ;;
  esac
done <<< "$installed_taps"

for unused_tap in "${unused_taps[@]}"; do
  if ! HOMEBREW_DEVELOPER=1 brew untap --force "$unused_tap" > "$untap_log" 2>&1; then
    # A cancelled setup-php source fallback can leave root-owned tap files on
    # persistent CI runners. Repair only this unused checkout, then retry once.
    tap_path=$(php_darwin_tap_repository_path "$unused_tap") || exit 1
    if [ "${GITHUB_ACTIONS:-}" = true ] && [ -d "$tap_path" ] && [ ! -L "$tap_path" ] &&
      sudo -n true && sudo -n chown -R -P "$(id -u):$(id -g)" "$tap_path" &&
      sudo -n chmod -R u+rwX "$tap_path" &&
      HOMEBREW_DEVELOPER=1 brew untap --force "$unused_tap" >> "$untap_log" 2>&1; then
      printf 'Repaired permissions for unused CI tap %s\n' "$unused_tap"
    else
      cat "$untap_log" >&2
      php_darwin_die 'could not remove unused Homebrew taps'
    fi
  fi
done

printf 'Removed %s unused Homebrew tap(s)\n' "${#unused_taps[@]}"
