#!/usr/bin/env bash
set -euo pipefail
state="$RUNNER_TEMP/first-ppa-extension"
mkdir -p "$state"
archive=/tmp/php_8.0-nts+ubuntu22.04.tar.zst
if [[ "$CACHE" == published ]]; then
  echo "0e0e276554657c78aed35d499e4f45573fe68847006a247c8862986db0fc9da1  $archive" | sha256sum --check
else
  cmp "$archive" builder/builds/php_8.0-nts+ubuntu22.04.tar.zst
  # The published installer clears Launchpad lists when it extracts a new cache.
  # Fetch the live PPA index so the PPA is a real candidate in the coexistence case.
  source_file=$(grep -El 'ppa\.launchpad(content)?\.net/ondrej/php/ubuntu' /etc/apt/sources.list.d/*.{list,sources} 2>/dev/null | sort -u || true)
  test -f "$source_file"
  sudo apt-get -o Dir::Etc::sourcelist="$source_file" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 -o APT::Update::Error-Mode=any update
  printf '%s\n' 'Package: php8.0-rdkafka' 'Pin: origin "ppa.launchpadcontent.net"' 'Pin-Priority: 990' | sudo tee /etc/apt/preferences.d/qa-rdkafka-from-ppa
fi
sudo rm -f /tmp/sp_update
stat -c '%y %i %s' "$archive" > "$state/archive.before"
for package in php8.0-cli php8.0-fpm php8.0-common; do
  dpkg-query -W "$package"
done | tee "$state/php.before"
sha256sum /usr/bin/php8.0 /usr/sbin/php-fpm8.0 | tee "$state/binaries.before"
if php8.0 -r 'exit(extension_loaded("rdkafka") ? 0 : 1);' || [[ -e "$(php-config8.0 --extension-dir)/rdkafka.so" ]]; then
  echo 'rdkafka must be absent before its first installation' >&2
  exit 1
fi
apt-cache policy php8.0-rdkafka php8.0-cli php8.0-common php8.0-fpm
apt-cache madison php8.0-rdkafka | awk -F ' *\\| *' '$3 ~ /ppa.launchpad(content)?\.net\/ondrej\/php/ {print $2; exit}' > "$state/ppa-version"
test -s "$state/ppa-version"
apt-get -s install php8.0-rdkafka | tee "$state/apt-plan"
sudo stat -c %s /var/log/dpkg.log | tee "$state/dpkg-offset" >/dev/null
