#!/usr/bin/env bash
set -euo pipefail

mkdir -p validation-logs
exec > >(tee validation-logs/validation.log) 2>&1
trap 'printf "FAIL at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
sw_vers
test "$(uname -m)" = arm64

brew_prefix=$(brew --prefix)
tap_repo=$(brew --repo shivammathur/php)
keg="$brew_prefix/Cellar/$PHP_FORMULA/${PHP_FULL_VERSION}_$PHP_REVISION"
opt="$brew_prefix/opt/$PHP_FORMULA"
config_dir="$brew_prefix/etc/php/$PHP_VERSION$PHP_SUFFIX"
pear_dir="$brew_prefix/share/$PHP_PEAR_DIRECTORY"

# setup-php downloads tap archives without .git, so compare the actual recipe
# against the immutable publication commit instead of consulting a parent repo.
curl --fail --silent --show-error --location \
  "https://raw.githubusercontent.com/shivammathur/homebrew-php/$EXPECTED_TAP_COMMIT/Formula/$PHP_FORMULA.rb" \
  --output validation-logs/published-formula.rb
cmp "$tap_repo/Formula/$PHP_FORMULA.rb" validation-logs/published-formula.rb
printf 'PASS: tap recipe matches publication %s\n' "$EXPECTED_TAP_COMMIT"
test -d "$keg"
test "$(cd "$opt" && pwd -P)" = "$keg"
test "$(php -r 'echo realpath(PHP_BINARY);')" = "$keg/bin/php"
jq -e '.poured_from_bottle == true and .built_as_bottle == true' "$keg/INSTALL_RECEIPT.json"
cp "$keg/INSTALL_RECEIPT.json" validation-logs/
cp "$keg/.brew/$PHP_FORMULA.rb" validation-logs/packaged-formula.rb
grep -q 'post_install_steps do' "$keg/.brew/$PHP_FORMULA.rb"
if grep -Eq 'def post_install|deny_network_access!.*postinstall' "$keg/.brew/$PHP_FORMULA.rb"; then
  echo 'Packaged formula still contains a legacy hook or blocks channel updates' >&2
  exit 1
fi

php -v
php --ini
php -m
php -r 'if (PHP_VERSION !== getenv("PHP_FULL_VERSION") || (bool) PHP_DEBUG !== (getenv("PHP_EXPECT_DEBUG") === "true") || (bool) PHP_ZTS !== (getenv("PHP_EXPECT_ZTS") === "zts")) { fwrite(STDERR, "Wrong PHP version or build variant\n"); exit(1); }'
test "$(php -r 'echo php_ini_loaded_file();')" = "$config_dir/php.ini"
php -r 'if (!extension_loaded("Zend OPcache")) { fwrite(STDERR, "OPcache is not loaded\n"); exit(1); }'
"$opt/sbin/php-fpm" -t
"$opt/bin/phpdbg" -V
"$opt/bin/php-cgi" -m

extension_dir=$("$opt/bin/php-config" --extension-dir)
abi=$(basename "$extension_dir")
test -L "$keg/pecl"
test "$(readlink "$keg/pecl")" = "$brew_prefix/lib/php/pecl"
test -d "$brew_prefix/lib/php/pecl/$abi"
test "$(php -r 'echo ini_get("extension_dir");')" = "$brew_prefix/lib/php/pecl/$abi"
for extension in $PHP_SHARED_EXTENSIONS; do
  test -f "$opt/lib/php/$abi/$extension.so"
  grep -F "$opt/lib/php/$abi/$extension.so" "$config_dir/conf.d/ext-$extension.ini"
  PHP_CHECK_EXTENSION="$extension" php -r 'exit(extension_loaded(getenv("PHP_CHECK_EXTENSION") === "opcache" ? "Zend OPcache" : getenv("PHP_CHECK_EXTENSION")) ? 0 : 1);'
done
if [ "$PHP_VERSION" = "8.5" ]; then
  "$opt/bin/php" -n -r 'exit(extension_loaded("Zend OPcache") ? 0 : 1);'
fi

check_pear() {
  local key=$1 expected=$2 actual
  actual=$("$opt/bin/pear" config-get "$key" system)
  printf '%s = %s\n' "$key" "$actual"
  test "$actual" = "$expected"
}

check_pear php_ini "$config_dir/php.ini"
check_pear php_dir "$pear_dir"
check_pear doc_dir "$pear_dir/doc"
check_pear ext_dir "$brew_prefix/lib/php/pecl/$abi"
check_pear bin_dir "$opt/bin"
check_pear data_dir "$pear_dir/data"
check_pear cfg_dir "$pear_dir/cfg"
check_pear www_dir "$pear_dir/htdocs"
check_pear man_dir "$brew_prefix/share/man"
check_pear test_dir "$pear_dir/test"
check_pear php_bin "$opt/bin/php"
for directory in "$pear_dir" "$pear_dir/doc" "$pear_dir/data" "$pear_dir/cfg" "$pear_dir/htdocs" "$pear_dir/test"; do
  test -d "$directory"
done

# Verify the actual hook without modifying the published recipe.
brew postinstall --verbose "shivammathur/php/$PHP_FORMULA" 2>&1 | tee validation-logs/postinstall.log
if grep -Ei 'not responding|cannot retrieve|failed with message|php_network_getaddresses|post-install step did not complete' validation-logs/postinstall.log; then
  echo 'Post-install reported a failure despite its exit status' >&2
  exit 1
fi

# Generic install-step runs capture stdout even with --verbose. Exercise the
# installed PEAR explicitly so channel diagnostics are visible for every variant.
# PEAR may exit zero on failed updates, so require positive channel evidence too.
"$opt/bin/pear" update-channels 2>&1 | tee validation-logs/channels.log
if grep -Ei 'not responding|cannot retrieve|failed with message|php_network_getaddresses' validation-logs/channels.log; then
  echo 'PEAR channel update reported a failure despite its exit status' >&2
  exit 1
fi
for channel in doc.php.net pear.php.net pecl.php.net; do
  grep -F -e "Update of Channel \"$channel\" succeeded" -e "Channel \"$channel\" is up to date" validation-logs/channels.log
done

# Confirm that a second hook run leaves the working PHP configuration intact.
test "$(php -r 'echo php_ini_loaded_file();')" = "$config_dir/php.ini"
php -r 'exit(extension_loaded("Zend OPcache") ? 0 : 1);'
check_pear php_ini "$config_dir/php.ini"
check_pear ext_dir "$brew_prefix/lib/php/pecl/$abi"
printf 'PASS: %s %s_%s installed from a rebuilt bottle\n' "$PHP_FORMULA" "$PHP_FULL_VERSION" "$PHP_REVISION"
