#!/usr/bin/env bash
# Each case runs in its own process, using real PHP and compiled extensions.
set +e
repo=$1
case_dir=$2
scenario=$3
php_binary=$4
fixtures=$5
source "$repo/src/scripts/unix.sh"
source "$repo/src/scripts/extensions/add_extensions.sh"
version="pecl-validation-$$"
semver="$($php_binary -n -r 'echo PHP_VERSION;')"
ext_dir="$case_dir/extensions"
mkdir -p "$ext_dir" "$case_dir/conf.d"
export PHP_INI_SCAN_DIR="$case_dir/conf.d"
printf 'display_errors=On\ndisplay_startup_errors=On\nlog_errors=Off\n' > "$case_dir/php.ini"
php() { "$php_binary" -c "$case_dir/php.ini" "$@"; }
sudo() { "$@"; }
trap 'rm -f "/tmp/php${version}_extensions"' EXIT
fail_fast=false
requested=1.5.0
install_version=1.5.0
fallback_version=1.5.0
install_result=0
startup=false
expected_version=1.5.0
expected_exit=0
expected_warning=0
expected_install=1
expected_fallback=0
expected_cache=1
case "$scenario" in
  exact) ;;
  exact-strict) fail_fast=true ;;
  enabled) initial=1.5.0; expected_install=0 ;;
  cached) cached=1.5.0; expected_install=0 ;;
  fallback-exact) install_version=; install_result=1; expected_fallback=1 ;;
  fallback-mismatch) install_version=; install_result=1; fallback_version=2.0.1; expected_version=2.0.1; expected_fallback=1; expected_warning=1; expected_cache=0 ;;
  unpinned) requested=; install_version=2.0.1; expected_version=2.0.1; expected_cache=0 ;;
  unpinned-fallback) requested=; install_version=; install_result=1; fallback_version=2.0.1; expected_version=2.0.1; expected_fallback=1; expected_cache=0 ;;
  missing) install_version=; install_result=1; fallback_version=; expected_version=; expected_fallback=1; expected_cache=0 ;;
  strict-no-fallback) install_version=; install_result=1; fallback_version=2.0.1; fail_fast=true; expected_version=; expected_exit=1; expected_cache=0 ;;
  strict-wrong-success) install_version=2.0.1; fail_fast=true; expected_version=2.0.1; expected_exit=1; expected_cache=0 ;;
  strict-wrong-failure) install_version=2.0.1; install_result=1; fail_fast=true; expected_version=2.0.1; expected_exit=1; expected_cache=0 ;;
  wrong-success) install_version=2.0.1; expected_version=2.0.1; expected_warning=1; expected_cache=0 ;;
  prerelease) requested=1.5.0beta1; install_version=1.5.0-beta1; expected_version=1.5.0-beta1 ;;
  prerelease-strict) requested=1.5.0beta1; install_version=1.5.0-beta1; expected_version=1.5.0-beta1; fail_fast=true ;;
  prerelease-enabled) requested=1.5.0beta1; initial=1.5.0-beta1; expected_version=1.5.0-beta1; expected_install=0 ;;
  prerelease-cached) requested=1.5.0beta1; cached=1.5.0-beta1; expected_version=1.5.0-beta1; expected_install=0 ;;
  startup-missing) startup=true; install_version=; install_result=1; fallback_version=; expected_version=; expected_fallback=1; expected_cache=0 ;;
  startup-missing-strict) startup=true; install_version=; install_result=1; fail_fast=true; expected_version=; expected_exit=1; expected_cache=0 ;;
  startup-target-missing-strict) startup=target; install_version=; install_result=1; fail_fast=true; expected_version=; expected_exit=1; expected_cache=0 ;;
  startup-exact) startup=true ;;
  startup-cached) startup=true; cached=1.5.0; expected_install=0 ;;
  startup-mismatch) startup=true; install_version=; install_result=1; fallback_version=2.0.1; expected_version=2.0.1; expected_warning=1; expected_fallback=1; expected_cache=0 ;;
  startup-wrong-strict) startup=true; install_version=2.0.1; fail_fast=true; expected_version=2.0.1; expected_exit=1; expected_cache=0 ;;
  *) printf 'Unknown case: %s\n' "$scenario"; exit 2 ;;
esac
if [ "$startup" != false ]; then
  broken=missing
  [ "$startup" = target ] && broken=pecl_fixture
  printf 'extension="%s/%s.so"\n' "$case_dir" "$broken" >> "$case_dir/php.ini"
  php -r 'echo phpversion("pecl_fixture");' > "$case_dir/startup-warning.txt" 2>&1
  grep -q 'Warning: PHP Startup:' "$case_dir/startup-warning.txt" || exit 2
fi
enable_extension() {
  if [ -e "$ext_dir/$1.so" ]; then
    printf 'extension="%s/%s.so"\n' "$ext_dir" "$1" > "$case_dir/conf.d/fixture.ini"
  fi
}
get() {
  printf '<a><r><v>2.0.1</v><s>stable</s></r><r><v>1.5.0beta1</v><s>beta</s></r></a>\n'
}
pecl_install() {
  printf '%s\n' "$1" >> "$case_dir/installer-calls.txt"
  rm -f "$case_dir/conf.d/fixture.ini" "$ext_dir/pecl_fixture.so" "/tmp/php${version}_extensions"
  if [ -n "$install_version" ]; then
    cp "$fixtures/$install_version.so" "$ext_dir/pecl_fixture.so"
    enable_extension pecl_fixture extension
  fi
  return "$install_result"
}
add_extension_helper() {
  printf '%s\n' "$1" >> "$case_dir/fallback-calls.txt"
  if [ -n "$fallback_version" ]; then
    cp "$fixtures/$fallback_version.so" "$ext_dir/pecl_fixture.so"
    enable_extension pecl_fixture extension
  fi
}
[ -n "${initial:-}" ] && cp "$fixtures/$initial.so" "$ext_dir/pecl_fixture.so"
[ -n "${cached:-}" ] && cp "$fixtures/$cached.so" "$ext_dir/pecl_fixture-$requested"
# The parent verifies this manifest against the resulting PHP state and logs.
printf '%s\n' "$expected_exit" "$expected_warning" "$expected_install" "$expected_fallback" "$expected_cache" "$expected_version" "$requested" > "$case_dir/expected.txt"
add_pecl_extension pecl_fixture "$requested" extension
printf 'CONTINUED_AFTER_SETUP\n'
