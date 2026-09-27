#!/usr/bin/env bash
# BASH_ENV for CI diagnostics only; never bundled into the release installer.
php_darwin_trace_phase() {
  if [ -n "${PHP_DARWIN_PHASE:-}" ] &&
    [ "$PHP_DARWIN_PHASE" != "${php_darwin_previous_phase:-}" ]; then
    printf 'php-darwin: phase %s at %ss\n' "$PHP_DARWIN_PHASE" "$SECONDS" >&2
    php_darwin_previous_phase=$PHP_DARWIN_PHASE
  fi
}
trap php_darwin_trace_phase DEBUG

# setup-php invokes the downloaded php-darwin installer through run_script.
# Time the entire child, including its cleanup, without changing release code.
bash() {
  local started elapsed status install_log
  if [ "${repo:-}" != php-darwin ] || [ "${1:-}" != /tmp/install.sh ]; then
    command bash "$@"
    return $?
  fi
  started=$SECONDS
  # CI can exercise a candidate installer against existing published archives
  # before changing any release. Keep the action and its inputs unchanged.
  if [ -n "${PHP_DARWIN_TEST_INSTALLER:-}" ]; then
    shift
    set -- "$PHP_DARWIN_TEST_INSTALLER" "$@"
  fi
  install_log="${RUNNER_TEMP:?}/php-darwin-setup-install.log"
  if command bash "$@" >> "$install_log" 2>&1; then status=0; else status=$?; fi
  cat "$install_log"
  elapsed=$((SECONDS - started))
  printf 'setup-php cache installer completed in %ss (status %s)\n' "$elapsed" "$status"
  printf '%s\n' "$elapsed" > "${RUNNER_TEMP:?}/php-darwin-setup-install-seconds.txt"
  return "$status"
}
