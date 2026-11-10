#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} = true && $EUID -eq 0 ]] || exit 1
awk '/^# Variables$/ {exit} {print}' "${BASELINE_ROOT:?}/src/scripts/linux.sh" > /tmp/baseline-functions.sh
awk '/^# Variables$/ {exit} {print}' "${ACTION_ROOT:?}/src/scripts/linux.sh" > /tmp/fixed-functions.sh
export EVENTS="${EVIDENCE:?}/mock-events.txt"
: > "$EVENTS"
bash -euo pipefail <<'CASE'
command() {
  if [[ ${1:-} = -v && ${2:-} = apt-fast ]]; then return 1; fi
  builtin command "$@"
}
sudo() {
  if [[ $1 = tee ]]; then cat >/dev/null; else printf '%s\n' "$*" >> "$EVENTS"; fi
}
source /tmp/baseline-functions.sh
apt_install=true
link_apt_fast
before=$(trap -p EXIT)
install_packages simulated-package
after=$(trap -p EXIT)
printf 'Baseline before: %s\nBaseline after: %s\n' "$before" "$after"
[[ "$before" != "$after" && "$after" = *force-confnew* ]]
CASE
grep -Fx 'ln -sf /usr/bin/apt-get /usr/bin/apt-fast' "$EVENTS"
grep -Fx 'rm -f /etc/dpkg/dpkg.cfg.d/force-confnew' "$EVENTS"
! grep -q '^rm -f /usr/bin/apt-fast' "$EVENTS"
for variant in baseline fixed; do
  export variant
  bash -euo pipefail <<'CASE'
source "/tmp/$variant-functions.sh"
sudo() { "$@"; }
apt_install=true
link_apt_fast
before=$(trap -p EXIT)
install_packages simulated-package
if [[ "$variant" = fixed ]]; then [[ $(trap -p EXIT) = "$before" ]]; fi
CASE
  [[ ! -e /etc/dpkg/dpkg.cfg.d/force-confnew ]]
  if [[ "$variant" = baseline ]]; then
    [[ -L /usr/bin/apt-fast && $(readlink /usr/bin/apt-fast) = /usr/bin/apt-get ]]
    rm /usr/bin/apt-fast
    echo 'PASS: original released functions reproduce the real symlink leak'
  else
    [[ ! -e /usr/bin/apt-fast && ! -L /usr/bin/apt-fast ]]
    echo 'PASS: fixed functions preserve the EXIT trap and clean the symlink'
  fi
done
