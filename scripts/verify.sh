#!/usr/bin/env bash

version=${1:?}
case "$version" in
  5.6|7.0|7.1|7.2|7.3|7.4|8.0|8.1|8.2|8.3|8.4|8.5|8.6) ;;
  *) printf 'Unsupported PHP version: %s\n' "$version" >&2; exit 1 ;;
esac

actual_version=$(php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;') || exit 1
[ "$actual_version" = "$version" ] || {
  printf 'Installed PHP %s; expected %s\n' "$actual_version" "$version" >&2
  exit 1
}
php -v || exit 1
php -m >/dev/null || exit 1
config_version=$(php-config --version) || exit 1
case "$config_version" in
  "$version".*) ;;
  *) printf 'php-config returned %s; expected %s.x\n' "$config_version" "$version" >&2; exit 1 ;;
esac
pecl version >/dev/null || exit 1

formula="php@$version"
[ "$version" != 8.5 ] || formula=php
brew list --versions "$formula" || exit 1
missing=$(brew missing "$formula" 2>&1)
missing_status=$?
[ "$missing_status" -eq 0 ] || [ -n "$missing" ] || {
  printf 'Homebrew dependency validation failed without diagnostics\n' >&2
  exit 1
}
[ -z "$missing" ] || {
  printf 'Homebrew reports missing dependencies for %s: %s\n' "$formula" "$missing" >&2
  exit 1
}
brew linkage --test "$formula" || exit 1

formula_info=$(brew info --installed --json=v2 "$formula") || exit 1
printf '%s\n' "$formula_info" | jq -e --arg formula "$formula" '
  [.formulae[] | select(.name == $formula and
    (.linked_keg | type == "string" and length > 0))] | length == 1
' >/dev/null || exit 1

[ "$(< "${PHP_DARWIN_SENTINEL:?}")" = preserve-existing-homebrew-state ] || exit 1
[ "$(stat -f "%Lp" "$PHP_DARWIN_SENTINEL")" = 444 ] || exit 1
tap_path=$(brew --repository shivammathur/php) || exit 1
[ -d "$tap_path/.git" ] || exit 1
brew tap-info --json=v1 shivammathur/php | jq -e '
  length == 1 and .[0].name == "shivammathur/php" and
  .[0].installed and .[0].trusted
' >/dev/null || exit 1
[ "$(git -C "$tap_path" remote get-url origin)" = \
  https://github.com/shivammathur/homebrew-php ] || exit 1
[ "$(git -C "$tap_path" symbolic-ref --short HEAD)" = main ] || exit 1

brew unlink "$formula" || exit 1
brew uninstall --force --ignore-dependencies "$formula" || exit 1
if brew list --formula | grep -Eq '^php(@[0-9]+\.[0-9]+)?(-debug)?(-zts)?$'; then
  printf 'A Homebrew PHP formula remained after testing %s\n' "$version" >&2
  exit 1
fi
