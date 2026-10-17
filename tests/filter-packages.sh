#!/usr/bin/env bash
set -euo pipefail
action_dir=$1
for function_name in filter_packages self_hosted_helper; do
  eval "$(awk -v name="$function_name" '$0 == name "() {" {printing=1} printing {print} printing && $0 == "}" {exit}' "$action_dir/src/scripts/linux.sh")"
done
checks=0
pass() { checks=$((checks + 1)); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect_filter() {
  local label=$1 expected=$2 actual
  shift 2
  actual=$(filter_packages "$@") || fail "$label: unexpected failure"
  [ "$actual" = "$expected" ] || fail "$label: got [$actual], expected [$expected]"
  pass "$label"
}
expect_filter 'real installed packages' '' bash dpkg
expect_filter 'real installed and missing packages' setup-php-missing-1136 bash setup-php-missing-1136 dpkg
expect_filter 'empty list' ''
test_db=$(mktemp -d)
trap 'rm -rf "$test_db"' EXIT
architecture=$(dpkg --print-architecture)
if [ "$architecture" = arm64 ]; then foreign=amd64; else foreign=arm64; fi
remove_package() {
  awk -v package="$1" 'BEGIN {RS=""; ORS="\n\n"} index($0, "Package: " package "\n") != 1 {print}' "$test_db/status" > "$test_db/status.new"
  mv "$test_db/status.new" "$test_db/status"
}
add_record() {
  {
    printf 'Package: %s\nStatus: %s\nArchitecture: %s\nMulti-Arch: same\nVersion: 1.0\nMaintainer: Test <test@example.invalid>\nDescription: package fixture\n' "$1" "$2" "${3:-$architecture}"
    case "$2" in
      *triggers-awaited) printf 'Triggers-Awaited: fixture-triggers-pending\n' ;;
      *triggers-pending) printf 'Triggers-Pending: /fixture-trigger\n' ;;
    esac
    printf '\n'
  } >> "$test_db/status"
}
set_package() { remove_package "$1"; add_record "$@"; }
add_record fixture-installed 'install ok installed'
add_record fixture-held 'hold ok installed'
add_record fixture-removed 'deinstall ok config-files'
add_record fixture-unpacked 'install ok unpacked'
add_record fixture-half-configured 'install ok half-configured'
add_record fixture-half-installed 'install reinstreq half-installed'
add_record fixture-reinstall-required 'install reinstreq installed'
add_record fixture-triggers-awaited 'install ok triggers-awaited'
add_record fixture-triggers-pending 'install ok triggers-pending'
add_record fixture-multi 'install ok installed' "$architecture"
add_record fixture-multi 'install ok installed' "$foreign"
add_record fixture-mixed 'install ok installed' "$architecture"
add_record fixture-mixed 'install ok unpacked' "$foreign"
query_failure=false
dpkg-query() {
  [ "$query_failure" = false ] || return 2
  printf 'query\n' >> "$test_db/query-count"
  command dpkg-query --admindir="$test_db" "$@"
}
expect_filter 'installed and held omitted' '' fixture-installed fixture-held
expect_filter 'all missing kept in order' $'fixture-missing-b\nfixture-missing-a' fixture-missing-b fixture-missing-a
expect_filter 'missing retained despite dpkg nonzero status' fixture-missing fixture-installed fixture-missing fixture-held
for state in removed unpacked half-configured half-installed reinstall-required triggers-awaited triggers-pending; do
  expect_filter "$state retained" "fixture-$state" fixture-installed "fixture-$state" fixture-held
done
expect_filter 'installed architecture-qualified package' '' "fixture-installed:$architecture"
expect_filter 'unqualified installed multiarch package' '' fixture-multi
expect_filter 'both installed architectures' '' "fixture-multi:$architecture" "fixture-multi:$foreign"
expect_filter 'healthy architecture omitted' '' "fixture-mixed:$architecture"
expect_filter 'incomplete architecture retained' "fixture-mixed:$foreign" "fixture-mixed:$foreign"
expect_filter 'unqualified incomplete multiarch package retained' fixture-mixed fixture-mixed
expect_filter 'version request preserved' fixture-installed=2.0 fixture-installed=2.0
: > "$test_db/query-count"
expect_filter 'batch result' fixture-missing fixture-installed fixture-held fixture-missing
[ "$(wc -l < "$test_db/query-count")" -eq 1 ] || fail 'batch used multiple dpkg queries'
pass 'one dpkg query per batch'
expect_filter 'empty batch does not query dpkg' ''
[ "$(wc -l < "$test_db/query-count")" -eq 1 ] || fail 'empty list queried dpkg'
install_count=0
install_result=success
installed_args=()
install_packages() {
  install_count=$((install_count + 1))
  installed_args=("$@")
  [ "$install_result" = success ] || return 1
  for package in "$@"; do set_package "$package" 'install ok installed'; done
}
sudo() { :; }
apt-fast() { :; }
base_packages=(apt-transport-https ca-certificates curl file make jq unzip autoconf automake gcc g++ gnupg)
for package in "${base_packages[@]}"; do
  [ "$package" = curl ] || add_record "$package" 'install ok installed'
done
self_hosted_helper
[ "$install_count" -eq 1 ] && [ "${installed_args[*]}" = curl ] || fail 'only missing curl'
pass 'only missing curl passed to installer'
self_hosted_helper
[ "$install_count" -eq 1 ] || fail 'already installed invoked installer'
pass 'all installed skips apt'
remove_package curl
remove_package jq
set_package gnupg 'hold ok installed'
self_hosted_helper
[ "$install_count" -eq 2 ] && [ "${installed_args[*]}" = 'curl jq' ] || fail 'missing pair or held package'
pass 'only missing pair passed; held dependency skipped'
set_package curl 'install ok unpacked'
set_package file 'deinstall ok config-files'
self_hosted_helper
[ "$install_count" -eq 3 ] && [ "${installed_args[*]}" = 'curl file' ] || fail 'incomplete packages'
pass 'only incomplete packages passed'
remove_package curl
install_result=fail
if self_hosted_helper; then fail 'installation failure swallowed'; fi
[ "${installed_args[*]}" = curl ] || fail 'failed install received extra packages'
pass 'installation failure propagated'
query_failure=true
expect_filter 'query failure retains every requested package' $'curl\njq' curl jq
printf '\nAll %s filter and caller checks passed.\n' "$checks"
