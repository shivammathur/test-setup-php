#!/usr/bin/env bash
set -euo pipefail
bundle="$PWD/builder/builds/php_8.0-nts+ubuntu22.04.tar.zst"
scratch="$RUNNER_TEMP/cache-inspection"
mkdir -p "$scratch"
tar -I zstd -tf "$bundle" > "$scratch/manifest"
mapfile -t sources < <(grep -E '^\./etc/apt/sources\.list\.d/.*\.(list|sources)$' "$scratch/manifest")
test "${#sources[@]}" -eq 1
test "${sources[0]}" = "./etc/apt/sources.list.d/setup-php-ubuntu-sury-jammy.list"
if grep -Ei 'ondrej[-_/]|ppa\.launchpad(content)?\.net' "$scratch/manifest"; then exit 1; fi
tar -I zstd -xf "$bundle" -C "$scratch" --no-same-owner \
  "${sources[0]}" ./etc/apt/setup-php-sury-mirrors.txt ./usr/share/keyrings/sury-php-keyring.gpg \
  ./usr/bin/php8.0 ./var/lib/dpkg/status-diff \
  ./var/lib/apt/lists/_etc_apt_setup-php-sury-mirrors.txt_dists_jammy_InRelease
key="$scratch/usr/share/keyrings/sury-php-keyring.gpg"
gpgv --status-fd 1 --keyring "$key" "$scratch"/var/lib/apt/lists/*InRelease | grep -F 'VALIDSIG 15058500A0235D97F5D10063B188E2B695BD4743'
diff -u develop/src/configs/sury-mirrors "$scratch/etc/apt/setup-php-sury-mirrors.txt"
printf '%s\n' 'deb [arch=amd64 signed-by=/usr/share/keyrings/sury-php-keyring.gpg] mirror+file:/etc/apt/setup-php-sury-mirrors.txt jammy main' | diff -u - "$scratch/${sources[0]}"
sha256sum "$bundle" | tee "$scratch/archive.sha256" | tee -a "$GITHUB_STEP_SUMMARY"
