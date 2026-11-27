#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
evidence="$GITHUB_WORKSPACE/evidence"
managed_uri='mirror+file:/etc/apt/setup-php-sury-mirrors.txt'
case "$ROUTE" in
  primary) origin=https://packages.sury.org/php ;;
  fallback|sks) origin=https://ppa.setup-php.com/sury ;;
  *) exit 1 ;;
esac

# Ask APT for active, suite-specific targets and check the custom source file.
targets=$(apt-get indextargets --no-release-info --format '$(REPO_URI)' "Release: $VERSION_CODENAME" 'Identifier: Packages' 'Component: main' 'Architecture: amd64')
php_targets=$(printf '%s\n' "$targets" | grep -E 'ondrej/php/ubuntu|packages\.sury\.org/php|ppa\.setup-php\.com/sury|setup-php-sury-mirrors')
[[ "${php_targets%/}" == "$managed_uri" ]]
(
  set +u
  . "$GITHUB_WORKSPACE/action/src/scripts/tools/ppa.sh"
  check_ppa setup-php/sury "$managed_uri"
)
stage=${1:-initial}
source_targets=$(apt-get indextargets --no-release-info --format '$(REPO_URI)' "Release: $VERSION_CODENAME-proposed" 'Identifier: Sources')
printf '%s\n' "$source_targets" > "$evidence/$stage-unrelated-targets.txt"
shopt -s nullglob
sources=(/etc/apt/sources.list.d/*.{list,sources})
mapfile -t matches < <(grep -lF "$managed_uri" "${sources[@]}")
[[ "${#matches[@]}" == 1 ]]
managed=${matches[0]}
key=$(sed -nE 's/.*signed-by=([^] ]+).*/\1/p; s/^Signed-By:[[:space:]]*(.*)/\1/p' "$managed")
[[ -s "$key" ]]
diff -u <(printf 'https://packages.sury.org/php/\tpriority:1\nhttps://ppa.setup-php.com/sury/\tpriority:2\n') /etc/apt/setup-php-sury-mirrors.txt

# The repeated action must retain the exact signed source, mirror priorities and unrelated entry.
sha256sum "$managed" "$key" /etc/apt/setup-php-sury-mirrors.txt /etc/apt/sources.list.d/qa-start.* > "$evidence/$stage-config.sha256"
actual_php=$(php -r 'if (!extension_loaded("redis")) exit(1); echo PHP_VERSION;')
[[ "$actual_php" == "$ACTION_PHP_VERSION" && "$actual_php" == 8.2.* ]]
if [[ "$stage" == repeat ]]; then
  diff -u "$evidence/initial-config.sha256" "$evidence/repeat-config.sha256"
  echo "$actual_php" > "$evidence/repeat-php.txt"
  exit 0
fi

cp "$managed" "$evidence/managed-source.txt"
cp /etc/apt/setup-php-sury-mirrors.txt "$evidence/mirror-order.txt"
printf '%s\n' "$targets" > "$evidence/final-repositories.txt"

# Use an empty index directory to prove the selected server supplied and signed current
# metadata even if the runner originally had complete APT caches.
lists="$RUNNER_TEMP/qa-lists"
sudo install -d -m 755 "$lists"
apt_options=(-o "Dir::Etc::sourcelist=$managed" -o Dir::Etc::sourceparts=- -o "Dir::State::lists=$lists" -o Dir::State::status=/dev/null -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= -o Acquire::Retries=0)
sudo apt-get "${apt_options[@]}" -o APT::Update::Error-Mode=any update 2>&1 | tee "$evidence/index-fetch.log"
release=("$lists"/*_InRelease)
[[ "${#release[@]}" == 1 ]]
gpgv --status-fd 1 --keyring "$key" "${release[0]}" > "$evidence/signature.log"
grep -F '15058500A0235D97F5D10063B188E2B695BD4743' "$evidence/signature.log"
grep -F 'Origin: deb.sury.org' "${release[0]}"
grep -F "Codename: $VERSION_CODENAME" "${release[0]}"

download="$RUNNER_TEMP/qa-debs"
mkdir -p "$download"
cd "$download"
packages=(php8.2-cli php8.2-redis php8.2-igbinary php8.2-msgpack)
apt-get "${apt_options[@]}" download "${packages[@]}" 2>&1 | tee "$evidence/package-fetch.log"

python3 - "$origin" "$evidence" "${packages[@]}" <<'PY'
from pathlib import Path
import re
import sys
origin, directory, *packages = sys.argv[1:]
for filename, targets in [('index-fetch.log', ['InRelease', 'Packages']), ('package-fetch.log', packages)]:
    lines = Path(directory, filename).read_text().splitlines()
    hits = [line.split() for line in lines if re.match(r'^Get:\d+ https?://', line)]
    assert hits and all(line[1].rstrip('/') == origin for line in hits), lines
    for target in targets:
        assert any(target in line[2:] for line in hits), (target, lines)
PY

for package in "${packages[@]}"; do
  files=("$package"_*.deb)
  [[ "${#files[@]}" == 1 ]]
  deb=${files[0]}
  [[ "$(dpkg-deb -f "$deb" Package)" == "$package" ]]
  version=$(dpkg-deb -f "$deb" Version)
  arch=$(dpkg-deb -f "$deb" Architecture)
  [[ "$arch" == amd64 ]]
  expected=$(apt-cache "${apt_options[@]}" show "$package=$version" | awk '$1 == "SHA256:" {print $2}')
  echo "$expected  $deb" | sha256sum -c -
  printf '%s\t%s\t%s\t%s\n' "$package" "$version" "$arch" "$expected" >> "$evidence/packages.tsv"
  dpkg-deb -x "$deb" "$download/extracted"
done
extensions=("$download"/extracted/usr/lib/php/*/redis.so)
extdir=$(dirname "${extensions[0]}")
"$download/extracted/usr/bin/php8.2" -n -d "extension_dir=$extdir" -d extension=igbinary -d extension=msgpack -d extension=redis \
  -r 'if (!class_exists("Redis") || PHP_MAJOR_VERSION !== 8 || PHP_MINOR_VERSION !== 2) exit(1); printf("PHP %s Redis %s\n", PHP_VERSION, phpversion("redis"));' |
  tee "$evidence/downloaded-runtime.txt"
printf '%s\n' "$actual_php" > "$evidence/action-php.txt"
printf '%s\n' "$origin" > "$evidence/origin.txt"
