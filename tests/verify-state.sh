#!/usr/bin/env bash
set -euo pipefail
if [[ ${EXISTING_APT:?} = true ]]; then
  sha256sum -c "$EVIDENCE/apt-fast.sha256"
  [[ $(stat -c '%a:%u:%g:%i' /usr/bin/apt-fast) = "$(cat "$EVIDENCE/apt-fast.stat")" ]]
else
  [[ ! -e /usr/bin/apt-fast && ! -L /usr/bin/apt-fast ]]
  ! command -v apt-fast
fi
if [[ ${EXISTING_MARKER:?} = true ]]; then
  sha256sum -c "$EVIDENCE/marker.sha256"
  [[ $(stat -c '%a:%u:%g:%i' /etc/dpkg/dpkg.cfg.d/force-confnew) = "$(cat "$EVIDENCE/marker.stat")" ]]
else
  [[ ! -e /etc/dpkg/dpkg.cfg.d/force-confnew && ! -L /etc/dpkg/dpkg.cfg.d/force-confnew ]]
fi
printf 'PASS: complete action preserves existing files and leaves no temporary files\n'
