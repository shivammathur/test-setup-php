#!/usr/bin/env bash
set -euo pipefail
action_dir=$1
os=Linux
eval "$(sed -n '/^check_installed() {$/,/^}$/p' "$action_dir/src/scripts/unix.sh")"
for function_name in self_hosted_helper; do
  eval "$(sed -n "/^${function_name}() {$/,/^}$/p" "$action_dir/src/scripts/linux.sh")"
done
for function_name in add_lib_log add_linux_libs; do
  eval "$(sed -n "/^${function_name}() {$/,/^}$/p" "$action_dir/src/scripts/extensions/source.sh")"
done
checks=0
pass() { checks=$((checks + 1)); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect_success() { local label=$1; shift; "$@" || fail "$label"; pass "$label"; }
expect_failure() { local label=$1; shift; if "$@"; then fail "$label"; fi; pass "$label"; }
expect_success 'real database: bash and dpkg installed' check_installed bash dpkg
expect_failure 'real database: installed and missing' check_installed bash setup-php-missing-package-1136
expect_failure 'empty argument list' check_installed
test_db=$(mktemp -d)
trap 'rm -rf "$test_db"' EXIT
architecture=$(dpkg --print-architecture)
write_package() {
  {
    printf 'Package: %s\nStatus: %s\nArchitecture: %s\nVersion: 1.0\nMaintainer: Test <test@example.invalid>\nDescription: package status fixture\n' "$1" "$2" "$architecture"
    case "$2" in
      *triggers-awaited) printf 'Triggers-Awaited: fixture-triggers-pending\n' ;;
      *triggers-pending) printf 'Triggers-Pending: /fixture-trigger\n' ;;
    esac
    printf '\n'
  } >> "$test_db/status"
}
write_package fixture-installed 'install ok installed'
write_package fixture-held 'hold ok installed'
write_package fixture-removed 'deinstall ok config-files'
write_package fixture-unpacked 'install ok unpacked'
write_package fixture-half-configured 'install ok half-configured'
write_package fixture-half-installed 'install reinstreq half-installed'
write_package fixture-reinstall-required 'install reinstreq installed'
write_package fixture-triggers-awaited 'install ok triggers-awaited'
write_package fixture-triggers-pending 'install ok triggers-pending'
dpkg-query() { command dpkg-query --admindir="$test_db" "$@"; }
expect_success 'installed package' check_installed fixture-installed
expect_success 'held installed package' check_installed fixture-held
expect_success 'installed and held packages' check_installed fixture-installed fixture-held
expect_success 'architecture-qualified package' check_installed "fixture-installed:$architecture"
expect_failure 'missing package' check_installed fixture-missing
expect_failure 'installed and missing packages' check_installed fixture-installed fixture-missing
for state in removed unpacked half-configured half-installed reinstall-required triggers-awaited triggers-pending; do
  expect_failure "$state package" check_installed "fixture-$state"
  expect_failure "installed and $state packages" check_installed fixture-installed "fixture-$state"
done
os=Linux
tick=OK
cross=FAIL
install_count=0
install_result=success
installed_args=()
last_log=()
install_packages() {
  install_count=$((install_count + 1))
  installed_args=("$@")
  [ "$install_result" = success ] || return 1
  for package in "$@"; do
    check_installed "$package" || write_package "$package" 'install ok installed'
  done
}
add_log() { last_log=("$@"); }
sudo() { :; }
apt-fast() { :; }
base_packages=(apt-transport-https ca-certificates curl file make jq unzip autoconf automake gcc g++ gnupg)
for package in "${base_packages[@]}"; do
  [ "$package" = jq ] || write_package "$package" 'install ok installed'
done
self_hosted_helper
[ "$install_count" -eq 1 ] && [ "${installed_args[*]}" = "${base_packages[*]}" ] || fail 'self-hosted missing dependency'
pass 'self-hosted missing dependency passes full list to installer'
self_hosted_helper
[ "$install_count" -eq 1 ] || fail 'self-hosted already installed'
pass 'self-hosted installed dependencies skip installer'
add_linux_libs fixture-installed
[ "$install_count" -eq 1 ] && [ "${last_log[*]}" = 'OK fixture-installed Installed' ] || fail 'installed library'
pass 'installed library skips installer and logs success'
add_linux_libs fixture-held
[ "$install_count" -eq 1 ] || fail 'held library'
pass 'held library skips installer'
add_linux_libs fixture-new-library
[ "$install_count" -eq 2 ] && [ "${last_log[*]}" = 'OK fixture-new-library Installed' ] || fail 'missing library'
pass 'missing library installs and logs success'
install_result=fail
add_linux_libs fixture-removed
[ "$install_count" -eq 3 ] && [ "${last_log[*]}" = 'FAIL fixture-removed Could not install fixture-removed' ] || fail 'removed library'
pass 'removed library attempts installation and logs failure'
add_linux_libs fixture-half-configured
[ "$install_count" -eq 4 ] && [ "${last_log[0]}" = FAIL ] || fail 'partial library'
pass 'partial library attempts installation and logs failure'
os=Darwin
brew_prefix="$test_db/brew"
mkdir -p "$brew_prefix/Cellar/fixture-brew"
expect_success 'macOS installed library unchanged' check_installed fixture-brew
expect_failure 'macOS missing library unchanged' check_installed fixture-missing
expect_success 'macOS multiple installed libraries' check_installed fixture-brew fixture-brew
expect_failure 'macOS mixed installed and missing libraries' check_installed fixture-brew fixture-missing
expect_failure 'macOS empty argument list' check_installed
printf '\nAll %s package-state and caller checks passed.\n' "$checks"
