#!/usr/bin/env bash

. /etc/os-release

packages=(unixodbc-dev libmagickcore-dev libxmlrpc-epi-dev)

printf 'runner=%s\n' "${RUNNER_NAME:-unknown}"
printf 'image=%s\n' "${ImageOS:-unknown}"
printf 'os=%s\n' "$PRETTY_NAME"
printf 'arch=%s\n' "$(dpkg --print-architecture)"
printf '\n'

sudo apt-get update

printf 'Package status before installing anything:\n'
for package in "${packages[@]}"; do
  if dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' "$package" 2>/dev/null | grep -q 'install ok installed'; then
    printf '%s\tinstalled\t' "$package"
    dpkg-query -W -f='${Version}\n' "$package"
  else
    printf '%s\tnot-installed\n' "$package"
  fi
done

printf '\nApt candidates:\n'
for package in "${packages[@]}"; do
  printf '\n== %s ==\n' "$package"
  apt-cache policy "$package"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### %s\n\n' "${RUNNER_NAME:-runner}"
    printf '`%s` `%s`\n\n' "$PRETTY_NAME" "$(dpkg --print-architecture)"
    printf '| Package | Runner status | Version |\n'
    printf '| --- | --- | --- |\n'
    for package in "${packages[@]}"; do
      if dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' "$package" 2>/dev/null | grep -q 'install ok installed'; then
        printf '| `%s` | installed | `%s` |\n' "$package" "$(dpkg-query -W -f='${Version}' "$package")"
      else
        printf '| `%s` | not installed |  |\n' "$package"
      fi
    done
  } >> "$GITHUB_STEP_SUMMARY"
fi
