#!/usr/bin/env bash
set -euo pipefail

# Older jobs can leave shallow core taps on persistent runners. Homebrew refuses
# to update them. Repair history only in CI, without changing the pinned tree.
[ "${GITHUB_ACTIONS:-}" = true ] || exit 0
core=${1:?Homebrew core path required}
[ "$(git -C "$core" rev-parse --is-shallow-repository)" = true ] || exit 0
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/retry.sh
. "$script_dir/../lib/retry.sh"
php_darwin_retry git -C "$core" fetch --unshallow --no-tags origin
