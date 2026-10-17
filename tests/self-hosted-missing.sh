#!/usr/bin/env bash
set -euo pipefail
action_dir=$1
os=Linux
eval "$(sed -n '/^check_installed() {$/,/^}$/p' "$action_dir/src/scripts/unix.sh")"
for function_name in install_packages self_hosted_helper; do
  eval "$(awk -v name="$function_name" '$0 == name "() {" {printing=1} printing {print} printing && $0 == "}" {exit}' "$action_dir/src/scripts/linux.sh")"
done
other_packages=(apt-transport-https ca-certificates file make jq unzip autoconf automake gcc g++ gnupg)
dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' "${other_packages[@]}" > results/other-packages-before.tsv
{ sudo apt-get remove -y curl; } > results/remove-curl.log 2>&1
if check_installed curl; then
  echo 'curl was not removed' >&2
  exit 1
fi
: > results/apt-requested-packages.txt
record_apt_install() {
  printf '%s\n' "$@" >> results/apt-requested-packages.txt
  { sudo env DEBIAN_FRONTEND=noninteractive apt-fast install -y --no-install-recommends "$@"; } > results/install-curl.log 2>&1
}
apt_install=record_apt_install
update_lists() { echo 'Unexpected apt installation failure' >&2; return 1; }
self_hosted_helper
check_installed curl
printf 'curl\n' | cmp - results/apt-requested-packages.txt
dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' "${other_packages[@]}" > results/other-packages-after.tsv
diff -u results/other-packages-before.tsv results/other-packages-after.tsv
self_hosted_helper
printf 'curl\n' | cmp - results/apt-requested-packages.txt
sudo apt-mark hold curl
self_hosted_helper
printf 'curl\n' | cmp - results/apt-requested-packages.txt
sudo apt-mark unhold curl
echo 'PASS: only curl passed to real apt; other dependencies unchanged; repeated and held checks skip apt'
