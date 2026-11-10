#!/usr/bin/env bash
set -euo pipefail
if [[ $EUID -eq 0 ]]; then
  root_cmd=()
else
  root_cmd=(sudo)
fi
"${root_cmd[@]}" apt-get update -qq
"${root_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sudo git curl ca-certificates aria2
mkdir -p evidence
curl --fail --silent --show-error --location --retry 3 https://raw.githubusercontent.com/ilikenwf/apt-fast/1f55b476b568f8589df8c040c2c1afd4a2384c4f/apt-fast -o evidence/apt-fast
cat /etc/os-release | tee evidence/os-release.txt
uname -a | tee evidence/uname.txt
