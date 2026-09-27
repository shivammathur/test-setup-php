#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-nightly-dispatch-test.XXXXXX") || \
  php_darwin_die 'could not create nightly dispatch fixtures'
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/bin" "$work_dir/conf" || exit 1
cat > "$work_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PHP_DARWIN_TEST_GH_LOG:?}"
exit "${PHP_DARWIN_TEST_GH_STATUS:-0}"
EOF
chmod 0755 "$work_dir/bin/gh" || exit 1
export PHP_DARWIN_TEST_GH_LOG="$work_dir/gh.log"
export PATH="$work_dir/bin:$PATH"
export GITHUB_REPOSITORY=shivammathur/php-darwin GITHUB_REF_NAME=feature/nightly-test
bash "$script_dir/../../release/dispatch-nightly.sh" || php_darwin_die 'nightly dispatch failed'
cat > "$work_dir/expected.log" <<'EOF'
workflow run cache-nightly.yml --repo shivammathur/php-darwin --ref feature/nightly-test -f php-version=8.6
workflow run cache-nightly.yml --repo shivammathur/php-darwin --ref feature/nightly-test -f php-version=8.7
EOF
cmp -s "$work_dir/expected.log" "$PHP_DARWIN_TEST_GH_LOG" || \
  php_darwin_die 'nightly dispatch did not start separate runs for both versions on the requested ref'

if PHP_DARWIN_TEST_GH_STATUS=1 bash "$script_dir/../../release/dispatch-nightly.sh" >/dev/null 2>&1; then
  php_darwin_die 'nightly dispatch ignored a workflow dispatch failure'
fi
for configuration in 'stable 8.5' 'nightly 8.7 unexpected'; do
  printf '%s\n' "$configuration" > "$work_dir/conf/versions" || exit 1
  : > "$PHP_DARWIN_TEST_GH_LOG"
  if PHP_DARWIN_ROOT="$work_dir" bash "$script_dir/../../release/dispatch-nightly.sh" >/dev/null 2>&1; then
    php_darwin_die 'nightly dispatch accepted missing or invalid nightly configuration'
  fi
  [ ! -s "$PHP_DARWIN_TEST_GH_LOG" ] || \
    php_darwin_die 'nightly dispatch started a workflow with invalid configuration'
done

printf 'Nightly dispatch validation passed (separate PHP 8.6 and 8.7 runs)\n'
