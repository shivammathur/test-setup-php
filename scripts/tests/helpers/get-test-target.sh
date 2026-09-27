#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

runner=${RUNNER:?}
arch=$(jq -er --arg runner "$runner" '
  to_entries | map(select(.value.test_runners | index($runner))) |
  if length == 1 then .[0].key else error("runner is not configured exactly once") end
' "$script_dir/../../../conf/platforms.json") || php_darwin_die "unsupported compatibility-test runner: $runner"
arch=$(php_darwin_normalize_arch "$arch") || exit 1

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'arch=%s\n' "$arch" >> "$GITHUB_OUTPUT" || php_darwin_die 'could not write the test architecture output'
else
  printf '%s\n' "$arch"
fi
