#!/usr/bin/env bash
set -euo pipefail
trap 'echo "::error::Verification failed on line $LINENO in $lane"' ERR
lane=$1
scratch="$RUNNER_TEMP/cache-inspection"
archive=php_8.0-nts+ubuntu22.04.tar.zst
test "$(wc -l < /var/tmp/php80-sury-qa/requests)" -eq "$2"
cmp "$GITHUB_WORKSPACE/builder/builds/$archive" "/tmp/$archive"
cmp "$scratch/usr/bin/php8.0" /usr/bin/php8.0
for file in /etc/apt/sources.list.d/setup-php-ubuntu-sury-jammy.list /etc/apt/setup-php-sury-mirrors.txt /usr/share/keyrings/sury-php-keyring.gpg; do
  cmp "$scratch$file" "$file"
done
mapfile -t targets < <(apt-get indextargets --no-release-info --format '$(REPO_URI)' 'Identifier: Packages' 'Architecture: amd64' |
  grep -E 'ondrej/php/ubuntu|/sury/?$|packages\.sury\.org/php|setup-php-sury-mirrors' | sort -u)
printf 'Active PHP repositories on %s\n%s\n' "$lane" "${targets[*]}"
printf '%s\n' "${targets[@]}" | grep -Fxq 'mirror+file:/etc/apt/setup-php-sury-mirrors.txt/'
if [[ "$lane" == v2 ]]; then
  printf '%s\n' "${targets[@]}" | grep -Fq 'ondrej/php/ubuntu'
else
  test "${#targets[@]}" -eq 1
fi
runtime=$(php -r 'if (PHP_MAJOR_VERSION !== 8 || PHP_MINOR_VERSION !== 0 || !extension_loaded("redis") || !extension_loaded("curl")) exit(1); echo PHP_VERSION;')
test "$runtime" = "$ACTION_PHP_VERSION"
php -v
php-config --version
phpize --version
sudo php-fpm8.0 -t
sudo service php8.0-fpm status
php -m > "$RUNNER_TEMP/$lane-modules" 2>&1
if grep -Ei 'PHP (Warning|Fatal error)|Unable to load|undefined symbol' "$RUNNER_TEMP/$lane-modules"; then exit 1; fi
sudo apt-get check
php_package=$(dpkg-query -W -f='${Version}' php8.0-cli)
[[ "$php_package" == *debsuryorg22.04* ]]
apt-cache policy php8.0-cli php8.0-rdkafka
sudo apt-get install -y --no-install-recommends php8.0-rdkafka
php8.0 -r 'if (!extension_loaded("rdkafka")) exit(1);'
bash builder/scripts/check-test-packages.sh 8.0 ubuntu-22.04 success success
grep -Fxq 'broken=false' reports/8.0-ubuntu-22.04.env
printf '%s restored the local archive, PHP %s (%s), FPM, Redis, curl, rdkafka, APT and dpkg checks passed.\n' "$lane" "$runtime" "$php_package" | tee -a "$GITHUB_STEP_SUMMARY"
