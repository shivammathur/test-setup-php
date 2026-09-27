#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "${PHP_DARWIN_NODE:-node}" "$script_dir/php-recovery.cjs" "${1:?}"
