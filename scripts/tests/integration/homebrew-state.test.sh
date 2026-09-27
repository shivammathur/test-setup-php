#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

fixture_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-validation.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT
phase_failure_log="$fixture_dir/phase-failure.log"
invalid_update_root="$fixture_dir/invalid-update-root"
tap_fixture="$fixture_dir/tap"
tap_backup="$fixture_dir/tap-backup"
tap_symlink="$fixture_dir/tap-symlink"
tap_brew_prefix="$fixture_dir/brew"
mkdir -p "$invalid_update_root/conf" || php_darwin_die 'could not create the invalid update fixture'
cp "$script_dir/../../../conf/package.json" "$invalid_update_root/conf/package.json" || \
  php_darwin_die 'could not stage the update package configuration fixture'
printf 'stable 8.5 unexpected\n' > "$invalid_update_root/conf/versions" || \
  php_darwin_die 'could not write the invalid update version fixture'
if PHP_DARWIN_ROOT="$invalid_update_root" bash "$script_dir/../../release/update.sh" >/dev/null 2>&1; then
  php_darwin_die 'stable cache update silently accepted invalid version configuration'
fi
if bash -c '
  . "$1"
  PHP_DARWIN_PHASE=archive.extract
  php_darwin_die "fixture extraction error"
' _ "$script_dir/../../lib/lib.sh" > /dev/null 2> "$phase_failure_log"; then
  php_darwin_die 'phase failure fixture unexpectedly succeeded'
fi
grep -Fq 'php-darwin: archive.extract failed: fixture extraction error' "$phase_failure_log" || \
  php_darwin_die 'installer did not explain its phase failure'
if ! (
  brew() { printf '{"taps":["shivammathur/php"],"formulae":[]}\n'; }
  php_darwin_tap_trusted shivammathur/php
); then
  php_darwin_die 'Homebrew trust helper did not recognize a trusted tap'
fi
if (
  brew() { printf '{"taps":[],"formulae":[]}\n'; }
  php_darwin_tap_trusted shivammathur/php
); then
  php_darwin_die 'Homebrew trust helper accepted an untrusted tap'
fi
if ! php_darwin_formula_trusted shivammathur/php/php \
  '{"taps":[],"formulae":["shivammathur/php/php"]}'; then
  php_darwin_die 'Homebrew trust helper did not recognize a trusted formula'
fi
if php_darwin_formula_trusted shivammathur/php/php '{"taps":[],"formulae":[]}'; then
  php_darwin_die 'Homebrew trust helper accepted an untrusted formula'
fi
(
  brew() { printf '{"invalid":true}\n'; }
  php_darwin_tap_trusted shivammathur/php 2>/dev/null
  [ "$?" -eq 2 ]
) || php_darwin_die 'Homebrew trust helper masked malformed trust state'

receipt_prefix="$fixture_dir/receipt-prefix"
mkdir -p "$receipt_prefix/Cellar/php@8.4/8.4.16" || \
  php_darwin_die 'could not create the formula receipt fixture'
printf '{"source":{"tap":"shivammathur/php"}}\n' \
  > "$receipt_prefix/Cellar/php@8.4/8.4.16/INSTALL_RECEIPT.json" || \
  php_darwin_die 'could not write the formula receipt fixture'
[ "$(php_darwin_keg_formula_reference "$receipt_prefix" php@8.4 Cellar/php@8.4/8.4.16 \
  shivammathur/php)" = \
  shivammathur/php/php@8.4 ] || \
  php_darwin_die 'tap formula receipt did not resolve to a fully-qualified reference'
printf '{"source":{"tap":"homebrew/core"}}\n' \
  > "$receipt_prefix/Cellar/php@8.4/8.4.16/INSTALL_RECEIPT.json" || \
  php_darwin_die 'could not update the formula receipt fixture'
[ "$(php_darwin_keg_formula_reference "$receipt_prefix" php@8.4 Cellar/php@8.4/8.4.16 \
  shivammathur/php)" = php@8.4 ] || \
  php_darwin_die 'core formula receipt did not resolve to a bare reference'

[ "$(php_darwin_prepare_tap_path "$tap_fixture" "$tap_backup")" = absent ] || \
  php_darwin_die 'absent Homebrew tap fixture returned the wrong state'
git init -q "$tap_fixture" || php_darwin_die 'could not create the Git tap fixture'
[ "$(php_darwin_prepare_tap_path "$tap_fixture" "$tap_backup")" = git ] || \
  php_darwin_die 'Git Homebrew tap fixture returned the wrong state'
[ -d "$tap_fixture/.git" ] || php_darwin_die 'Git Homebrew tap fixture was moved'
rm -rf "$tap_fixture/.git"
worktree_source="$fixture_dir/worktree-source"
worktree_tap="$fixture_dir/worktree-tap"
git init -q -b main "$worktree_source" || php_darwin_die 'could not create a worktree source fixture'
printf 'fixture\n' > "$worktree_source/fixture" || php_darwin_die 'could not write a worktree fixture'
git -C "$worktree_source" add fixture || php_darwin_die 'could not stage the worktree fixture'
git -C "$worktree_source" -c user.name=php-darwin -c user.email=php-darwin@example.invalid \
  commit -q -m fixture || php_darwin_die 'could not commit the worktree fixture'
git -C "$worktree_source" worktree add -q --detach "$worktree_tap" HEAD || \
  php_darwin_die 'could not create a linked worktree fixture'
[ -f "$worktree_tap/.git" ] || php_darwin_die 'linked worktree fixture did not use a Git file'
[ "$(php_darwin_prepare_tap_path "$worktree_tap" "$tap_backup")" = git ] || \
  php_darwin_die 'linked Homebrew tap worktree was not preserved'
[ -d "$worktree_tap" ] || php_darwin_die 'linked Homebrew tap worktree was moved'
mkdir -p "$worktree_source/Library/Taps/example/homebrew-false-tap" || \
  php_darwin_die 'could not create the parent-repository tap fixture'
if php_darwin_is_git_worktree "$worktree_source/Library/Taps/example/homebrew-false-tap"; then
  php_darwin_die 'tap detection inherited Git state from a parent repository'
fi
printf 'runner-placeholder\n' > "$tap_fixture/Formula.php"
[ "$(php_darwin_prepare_tap_path "$tap_fixture" "$tap_backup")" = backed-up ] || \
  php_darwin_die 'non-Git Homebrew tap fixture returned the wrong state'
[ ! -e "$tap_fixture" ] && [ "$(cat "$tap_backup/Formula.php")" = runner-placeholder ] || \
  php_darwin_die 'non-Git Homebrew tap fixture was not backed up'
php_darwin_restore_tap_path "$tap_fixture" "$tap_backup" || \
  php_darwin_die 'non-Git Homebrew tap fixture could not be restored'
[ "$(cat "$tap_fixture/Formula.php")" = runner-placeholder ] || \
  php_darwin_die 'restored Homebrew tap fixture changed'
mkdir -p "$tap_brew_prefix/var/php-darwin" || php_darwin_die 'could not create the tap backup root fixture'
tap_fixture_path="$tap_brew_prefix/Library/Taps/shivammathur/homebrew-php"
mkdir -p "${tap_fixture_path%/*}" || php_darwin_die 'could not create the tap path fixture'
mv "$tap_fixture" "$tap_fixture_path" || php_darwin_die 'could not stage the tap path fixture'
tap_fixture=$tap_fixture_path
tap_backup=$(php_darwin_tap_backup_path "$tap_brew_prefix" "$tap_fixture" \
  "$fixture_dir/php-darwin-install.fixture") || \
  php_darwin_die 'could not resolve the same-filesystem tap backup fixture'
[ "$tap_backup" = "$tap_brew_prefix/var/php-darwin/tap-backup.php-darwin-install.fixture" ] || \
  php_darwin_die 'tap backup fixture was not in the Homebrew rollback directory'
[ "$(php_darwin_prepare_tap_path "$tap_fixture" "$tap_backup")" = backed-up ] || \
  php_darwin_die 'tap removal fixture was not backed up'
php_darwin_remove_tap_backup "$tap_brew_prefix" "$tap_backup" || \
  php_darwin_die 'same-filesystem Homebrew tap backup fixture could not be removed'
[ ! -e "$tap_backup" ] || php_darwin_die 'Homebrew tap backup fixture remained after removal'
git init -q "$tap_fixture" || php_darwin_die 'could not create the removable tap fixture'
php_darwin_remove_tap_path "$tap_brew_prefix" "$tap_fixture" || \
  php_darwin_die 'Homebrew tap fixture could not be removed transactionally'
[ ! -e "$tap_fixture" ] || php_darwin_die 'removed Homebrew tap fixture remained'
ln -s "$tap_fixture" "$tap_symlink" || php_darwin_die 'could not create the tap symlink fixture'
if php_darwin_prepare_tap_path "$tap_symlink" "$tap_backup" 2> /dev/null; then
  php_darwin_die 'Homebrew tap preparation accepted a symlink'
fi


printf 'homebrew-state validation passed\n'
