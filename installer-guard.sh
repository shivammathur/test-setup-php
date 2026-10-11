#!/usr/bin/env bash
# Observe the downloaded installer without replacing it or modifying setup-php.
# Exit on cache failure so stock setup-php cannot hide it by compiling PHP.
bash() {
  if [ "${repo:-}" != php-darwin ] || [ "${1:-}" != /tmp/install.sh ]; then
    command bash "$@"
    return $?
  fi
  local log status
  log="${GITHUB_WORKSPACE:?}/evidence/cache-install.log"
  cp /tmp/install.sh "${GITHUB_WORKSPACE:?}/evidence/published-install.sh" || exit 1
  if command bash "$@" > "$log" 2>&1; then status=0; else status=$?; fi
  cat "$log"
  [ "$status" -eq 0 ] || exit "$status"
}
