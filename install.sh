#!/usr/bin/env bash

. /etc/os-release

printf 'runner=%s\n' "${RUNNER_NAME:-unknown}"
printf 'image=%s\n' "${ImageOS:-unknown}"
printf 'os=%s\n' "$PRETTY_NAME"
printf 'arch=%s\n' "$(dpkg --print-architecture)"
printf '\n'

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates gnupg software-properties-common
sudo add-apt-repository -y ppa:ondrej/php
sudo apt-get update

printf '\nlibgd policy after adding ondrej/php:\n'
apt-cache policy libgd-dev libgd3

printf '\nlibgd dependency metadata after adding ondrej/php:\n'
apt-cache depends libgd3 libgd-dev

before=$(mktemp)
after=$(mktemp)
new_names=$(mktemp)
dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "$before"

printf '\nInstalling libgd-dev from ondrej/php:\n'
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libgd-dev

dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "$after"
comm -13 "$before" "$after" | tee /tmp/new-packages.tsv
cut -f1 /tmp/new-packages.tsv > "$new_names"

printf '\nnewly_installed_packages='
tr '\n' ' ' < "$new_names"
printf '\n'

printf '\nnewly_installed_count=%s\n' "$(wc -l < "$new_names" | xargs)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### %s\n\n' "${RUNNER_NAME:-runner}"
    printf 'Installed `libgd-dev` from `ondrej/php` on `%s`.\n\n' "$PRETTY_NAME"
    printf 'New packages:\n\n'
    printf '```text\n'
    cat /tmp/new-packages.tsv
    printf '```\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi
