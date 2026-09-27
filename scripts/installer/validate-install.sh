#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

root=$(cd "$script_dir/../.." && pwd)
installer="$root/scripts/install.sh"
files="$root/conf/install-files"
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-install-validation.XXXXXX") || \
  php_darwin_die 'could not create the standalone installer validation directory'
trap 'rm -rf "$work_dir"' EXIT
expected="$work_dir/install.sh"

bash "$script_dir/generate-install.sh" "$expected" >/dev/null || \
  php_darwin_die 'could not independently generate the standalone installer'
cmp -s "$installer" "$expected" || php_darwin_die 'standalone installer is stale'
bash -n "$installer" || php_darwin_die 'standalone installer has invalid shell syntax'
if grep -Eq 'php_darwin_(timed|timing_|set_phase)|PHP_DARWIN_TIMING|Time::HiRes' "$installer"; then
  php_darwin_die 'production installer contains debug timing instrumentation'
fi
if grep -Eq 'base64|PHP_DARWIN_PAYLOAD|PHP_DARWIN_CLIENT|gzip -d' "$installer"; then
  php_darwin_die 'standalone installer contains an encoded payload'
fi

if grep -Fq 'GITHUB_PATH' "$installer"; then
  php_darwin_die 'standalone installer must use Homebrew links instead of changing GITHUB_PATH'
fi
input_count=0
while IFS= read -r relative extra; do
  [ -n "$relative" ] || continue
  case "$relative" in \#*) continue ;; esac
  [ -z "$extra" ] || php_darwin_die "invalid standalone installer input: $relative $extra"
  input_count=$((input_count + 1))
  case "$relative" in
    scripts/*)
      grep -Fxq "# Source: $relative" "$installer" || \
        php_darwin_die "standalone installer omitted readable source $relative"
      ;;
    conf/*)
      config_name=${relative#conf/}
      grep -Fq "    $config_name)" "$installer" || \
        php_darwin_die "standalone installer omitted readable configuration $relative"
      ;;
  esac
done < "$files"
printf 'Standalone installer is readable and current (%s inputs)\n' "$input_count"
