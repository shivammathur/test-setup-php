#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
standard=/usr/share/keyrings/debsuryorg-archive-keyring.gpg
custom=/usr/share/keyrings/qa-existing-sury.gpg
shopt -s nullglob
managed=(/etc/apt/sources.list.d/setup-php-ubuntu-sury-"$VERSION_CODENAME".*)
[[ "${#managed[@]}" == 1 ]]
if [[ "$1" == prepare ]]; then
  sudo rm -- "${managed[0]}" /usr/share/keyrings/sury-php-keyring.gpg /etc/apt/setup-php-sury-mirrors.txt
  sudo install -m 644 "$custom" "$standard"
  fixture=$(cat evidence/fixture-path.txt)
  [[ "$fixture" == /etc/apt/sources.list.d/qa-start.list || "$fixture" == /etc/apt/sources.list.d/qa-start.sources ]]
  sed "s|$custom|$standard|g" evidence/starting-source.txt | sudo tee "$fixture" >/dev/null
  apt-get indextargets --no-release-info --format '$(REPO_URI)' "Release: $VERSION_CODENAME" 'Identifier: Packages' 'Component: main' 'Architecture: amd64' |
    sed 's:/*$::' | sort -u > evidence/warm-start-repositories.txt
  diff -u evidence/starting-repositories.txt evidence/warm-start-repositories.txt
else
  grep -F "$standard" "${managed[0]}" > evidence/installed-key.txt
  [[ ! -e /usr/share/keyrings/sury-php-keyring.gpg ]]
  cmp evidence/initial-requests.tsv /var/tmp/sury-key-qa/requests.tsv
  cmp "$standard" "$custom"
  php -r 'exit(PHP_MAJOR_VERSION === 8 && PHP_MINOR_VERSION === 2 && extension_loaded("redis") ? 0 : 1);'
fi
