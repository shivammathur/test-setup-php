#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} = true && $EUID -eq 0 ]] || exit 1
while apt_fast_path=$(command -v apt-fast); do
  [[ "$apt_fast_path" = /* ]] || exit 1
  rm -f "$apt_fast_path"
  hash -r
done
rm -f /usr/bin/apt-fast /etc/dpkg/dpkg.cfg.d/force-confnew
mkdir -p /etc/dpkg/dpkg.cfg.d "${EVIDENCE:?}"
if [[ ${EXISTING_APT:-false} = true ]]; then
  cp "${APT_FAST_SOURCE:?}" /usr/bin/apt-fast
  chmod 755 /usr/bin/apt-fast
  sha256sum /usr/bin/apt-fast > "$EVIDENCE/apt-fast.sha256"
  stat -c '%a:%u:%g:%i' /usr/bin/apt-fast > "$EVIDENCE/apt-fast.stat"
fi
if [[ ${EXISTING_MARKER:-false} = true ]]; then
  printf 'force-confnew\n# pre-existing issue-1156 marker\n' > /etc/dpkg/dpkg.cfg.d/force-confnew
  sha256sum /etc/dpkg/dpkg.cfg.d/force-confnew > "$EVIDENCE/marker.sha256"
  stat -c '%a:%u:%g:%i' /etc/dpkg/dpkg.cfg.d/force-confnew > "$EVIDENCE/marker.stat"
fi
# Ensure the self-hosted helper has a real missing package to install.
if dpkg-query -W -f='${db:Status-Status}' apt-transport-https 2>/dev/null | grep -qx installed; then
  apt-get remove -y apt-transport-https >/dev/null 2>&1
fi
printf 'Prepared apt-fast=%s force-confnew=%s\n' "${EXISTING_APT:-false}" "${EXISTING_MARKER:-false}"
