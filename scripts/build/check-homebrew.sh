#!/usr/bin/env bash
set -euo pipefail

# Run once after cleanup, before testing or building, rather than for every PHP
# variant. Keep configuration and all doctor output visible in the job log.
brew config
log=$(mktemp "${RUNNER_TEMP:-/tmp}/php-darwin-doctor.XXXXXX")
trap 'rm -f "$log"' EXIT
status=0
brew doctor > "$log" 2>&1 || status=$?
cat "$log"
if [ "$status" -ne 0 ] && grep -Eq '^(Error:|.*broken)' "$log"; then
  printf 'Homebrew is broken after runner cleanup\n' >&2
  exit "$status"
fi
