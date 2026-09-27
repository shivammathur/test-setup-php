#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
directory=${1:?}
metadata=$(find "$directory" -type f -name 'php_*.json' -print -quit)
test -n "$metadata"
export HOMEBREW_PHP_COMMIT HOMEBREW_EXTENSIONS_COMMIT
HOMEBREW_PHP_COMMIT=$(jq -er .homebrew_php_commit "$metadata")
HOMEBREW_EXTENSIONS_COMMIT=$(jq -er .homebrew_extensions_commit "$metadata")
for arch in arm64 x86_64; do
  found=$(find "$directory" -type f -name "php_*+darwin_$arch.json" -print -quit)
  if [ -z "$found" ]; then
    ARCH="$arch" bash "$script_dir/../cache/restore-published-architecture.sh" "$directory"
  fi
done
