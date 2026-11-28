#!/usr/bin/env bash
set -euo pipefail
state="$RUNNER_TEMP/first-ppa-extension"
offset=$(cat "$state/dpkg-offset")
sudo tail -c "+$((offset + 1))" /var/log/dpkg.log | tee "$state/dpkg.delta" >/dev/null
cat "$state/dpkg.delta" | grep -E ' (install|upgrade|trigproc|remove|purge) [^ ]+' || true
stat -c '%y %i %s' /tmp/php_8.0-nts+ubuntu22.04.tar.zst > "$state/archive.after"
diff -u "$state/archive.before" "$state/archive.after"
for package in php8.0-cli php8.0-fpm php8.0-common; do
  dpkg-query -W "$package"
done | tee "$state/php.after"
sha256sum /usr/bin/php8.0 /usr/sbin/php-fpm8.0 | tee "$state/binaries.after"
php8.0 --ri rdkafka | head -14 || true
php8.0 -r 'if (!extension_loaded("rdkafka")) exit(1);'
installed=$(dpkg-query -W -f='${Version}' php8.0-rdkafka)
expected=$(cat "$state/ppa-version")
echo "Installed extension $installed; Launchpad offered $expected"
test "$installed" = "$expected"
grep -E ' install php8.0-rdkafka(:[^ ]+)? ' "$state/dpkg.delta"
actions=$(awk '$3 ~ /^(install|upgrade|remove|purge)$/ && $4 ~ /^php8\.0-(cli|fpm)(:|$)/' "$state/dpkg.delta")
triggers=$(awk '$3 == "trigproc" && $4 ~ /^php8\.0-(cli|fpm)(:|$)/' "$state/dpkg.delta")
{
  echo "Cache $CACHE"
  echo "Launchpad extension $installed"
  echo "CLI/FPM package actions: ${actions:-none}"
  echo "CLI/FPM triggers: ${triggers:-none}"
  diff -u "$state/php.before" "$state/php.after" || true
} | tee -a "$GITHUB_STEP_SUMMARY"
sudo apt-get check
