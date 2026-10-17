#!/usr/bin/env bash
set -euo pipefail
action_dir=$1
eval "$(sed -n '/^check_installed() {$/,/^}$/p' "$action_dir/src/scripts/unix.sh")"
for function_name in install_packages; do
  eval "$(sed -n "/^${function_name}() {$/,/^}$/p" "$action_dir/src/scripts/linux.sh")"
done
for function_name in add_lib_log add_linux_libs; do
  eval "$(sed -n "/^${function_name}() {$/,/^}$/p" "$action_dir/src/scripts/extensions/source.sh")"
done
eval "$(declare -f install_packages | sed '1s/install_packages/original_install_packages/')"
install_count=0
install_packages() {
  install_count=$((install_count + 1))
  original_install_packages "$@"
}
update_lists() { echo 'Unexpected package installation failure' >&2; return 1; }
add_log() { printf '%s %s: %s\n' "$@"; }
os=Linux
tick=OK
cross=FAIL
apt_install='sudo DEBIAN_FRONTEND=noninteractive apt-fast install -y --no-install-recommends'
sudo apt-get purge -y sl >/dev/null 2>&1
if check_installed sl; then
  echo 'Test package unexpectedly installed' >&2
  exit 1
fi
add_linux_libs sl
check_installed sl
test "$install_count" -eq 1
test -x /usr/games/sl
add_linux_libs sl
test "$install_count" -eq 1
sudo apt-mark hold sl
add_linux_libs sl
test "$install_count" -eq 1
sudo apt-mark unhold sl
dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' sl
echo 'PASS: real missing package installed; repeat and held package skipped'
