#!/usr/bin/env bash
set -euo pipefail
action_dir=$1
os=Darwin
eval "$(sed -n '/^check_installed() {$/,/^}$/p' "$action_dir/src/scripts/unix.sh")"
for function_name in add_lib_log add_darwin_libs; do
  eval "$(awk -v name="$function_name" '$0 == name "() {" {printing=1} printing {print} printing && $0 == "}" {exit}' "$action_dir/src/scripts/extensions/source.sh")"
done
brew_prefix=$(brew --prefix)
installed_formula=$(brew list --formula | sed -n '1p')
test -n "$installed_formula"
check_installed "$installed_formula"
printf 'PASS: native Homebrew formula %s detected under %s\n' "$installed_formula" "$brew_prefix"
brew_prefix=$(mktemp -d)
trap 'rm -rf "$brew_prefix"' EXIT
mkdir -p "$brew_prefix/Cellar/fixture/1.0" "$brew_prefix/Cellar/fixture@1/1.0"
check_installed fixture 'fixture@1'
if check_installed fixture fixture-missing || check_installed; then
  echo 'Missing formula or empty list incorrectly accepted' >&2
  exit 1
fi
tick=OK
cross=FAIL
brew_count=0
brew_result=success
last_log=()
add_log() { last_log=("$@"); }
safe_brew() {
  brew_count=$((brew_count + 1))
  [ "$brew_result" = success ] || return 1
  mkdir -p "$brew_prefix/Cellar/${*: -1}/1.0"
}
add_darwin_libs fixture
test "$brew_count" -eq 0
test "${last_log[*]}" = 'OK fixture Installed'
add_darwin_libs fixture-new
test "$brew_count" -eq 1
test "${last_log[*]}" = 'OK fixture-new Installed'
brew_result=fail
add_darwin_libs fixture-failure
test "$brew_count" -eq 2
test "${last_log[*]}" = 'FAIL fixture-failure Could not install fixture-failure'
echo 'PASS: macOS batch, missing, empty, install, skip, and failure logging checks'
