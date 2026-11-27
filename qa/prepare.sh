#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
[[ "$ID/$VERSION_ID" == "ubuntu/$UBUNTU_VERSION" ]]
mkdir -p evidence
printf '%s\n' "$PRETTY_NAME / $START_STATE / $ROUTE" | tee evidence/case.txt

# Each job has a disposable hosted runner. Quarantine PHP sources supplied by its
# image before seeding the requested state. Leave the distro sources available.
shopt -s nullglob
backup="$RUNNER_TEMP/original-php-apt"
mkdir -p "$backup"
php_sources='(ppa\.launchpad(content)?\.net|setup-php\.com)/ondrej/php/ubuntu|packages\.sury\.org/php|ppa\.setup-php\.com/sury|setup-php-sury-mirrors'
for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.{list,sources}; do
  [[ -f "$file" ]] || continue
  if grep -Eq "$php_sources" "$file"; then
    sudo mv "$file" "$backup/"
  fi
done
for file in /etc/apt/setup-php-sury-mirrors.txt /usr/share/keyrings/{debsuryorg-archive-keyring,sury-php-keyring}.gpg; do
  [[ ! -e "$file" ]] || sudo mv "$file" "$backup/"
done
sudo find /var/lib/apt/lists -maxdepth 1 -type f \( -name '*ondrej*' -o -name '*sury*' \) -delete
sudo find /tmp -maxdepth 1 -type f \( -name 'os_lists*' -o -name 'sp_update' \) -delete

case "$START_STATE" in
  none) url='' ;;
  launchpad)
    url=https://ppa.launchpadcontent.net/ondrej/php/ubuntu
    [[ "$VERSION_ID" != '22.04' ]] || url=http://ppa.launchpad.net/ondrej/php/ubuntu
    ;;
  launchpad-mirror) url=https://ppa.setup-php.com/ondrej/php/ubuntu ;;
  sury) url=https://packages.sury.org/php/ ;;
  sury-mirror) url=https://ppa.setup-php.com/sury/ ;;
  *) exit 1 ;;
esac

if [[ -n "$url" ]]; then
  case "$START_STATE" in
    launchpad*) key_url=https://ppa.setup-php.com/keys/ondrej/php.gpg
      fingerprint=B8DC7E53946656EFBCE4C1DD71DAEAAB4AD4CAB6
      key=/usr/share/keyrings/qa-launchpad-php.gpg ;;
    *) key_url='https://keyserver.ubuntu.com/pks/lookup?op=get'
      fingerprint=15058500A0235D97F5D10063B188E2B695BD4743
      key_url="$key_url&search=0x$fingerprint"
      key=/usr/share/keyrings/debsuryorg-archive-keyring.gpg ;;
  esac
  curl -fsSL --max-time 30 --retry 2 "$key_url" -o "$RUNNER_TEMP/fixture-key"
  actual=$(gpg --batch --with-colons --show-keys "$RUNNER_TEMP/fixture-key" | awk -F: '$1=="fpr" && !seen++ {print $10}')
  [[ "$actual" == "$fingerprint" ]]
  gpg --batch --yes --dearmor -o "$RUNNER_TEMP/fixture-key.gpg" "$RUNNER_TEMP/fixture-key"
  sudo install -m 644 "$RUNNER_TEMP/fixture-key.gpg" "$key"
fi

# Keep a real, unrelated source entry in the same file throughout migration.
sentinel='https://archive.ubuntu.com/ubuntu/'
if [[ "$VERSION_ID" == '22.04' ]]; then
  fixture=/etc/apt/sources.list.d/qa-start.list
  {
    echo "deb-src [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $sentinel $VERSION_CODENAME-proposed main"
    [[ -z "$url" ]] || echo "deb [arch=amd64 signed-by=$key] $url $VERSION_CODENAME main"
  } | sudo tee "$fixture" >/dev/null
else
  fixture=/etc/apt/sources.list.d/qa-start.sources
  {
    printf 'Types: deb-src\nURIs: %s\nSuites: %s-proposed\nComponents: main\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' "$sentinel" "$VERSION_CODENAME"
    if [[ -n "$url" ]]; then
      printf '\nTypes: deb\nURIs: %s\nSuites: %s\nComponents: main\nArchitectures: amd64\nSigned-By: %s\n' "$url" "$VERSION_CODENAME" "$key"
    fi
  } | sudo tee "$fixture" >/dev/null
fi
cp "$fixture" evidence/starting-source.txt
apt-get indextargets --no-release-info --format '$(REPO_URI)' "Release: $VERSION_CODENAME" 'Identifier: Packages' 'Component: main' 'Architecture: amd64' |
  sed 's:/*$::' | sort -u > evidence/starting-repositories.txt
grep -Eq 'ubuntu' evidence/starting-repositories.txt
found=$(grep -E "$php_sources" evidence/starting-repositories.txt || true)
[[ "$found" == "${url%/}" ]]

if [[ "$ROUTE" == fallback ]]; then
  printf '127.0.0.1 packages.sury.org\n::1 packages.sury.org\n' | sudo tee -a /etc/hosts >/dev/null
  echo 'Acquire::https::Proxy::packages.sury.org "DIRECT";' | sudo tee /etc/apt/apt.conf.d/98qa-sury-outage >/dev/null
  for name in NO_PROXY no_proxy; do
    printf '%s=%s,packages.sury.org\n' "$name" "${!name:-}" >> "$GITHUB_ENV"
  done
  if curl --noproxy '*' -fsS --connect-timeout 2 --max-time 4 "https://packages.sury.org/php/dists/$VERSION_CODENAME/InRelease" -o /dev/null; then
    echo 'Primary is still reachable' >&2
    exit 1
  fi
fi
