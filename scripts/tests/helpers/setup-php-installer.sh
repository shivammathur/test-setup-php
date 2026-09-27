#!/usr/bin/env bash
# BASH_ENV for CI installer selection and failure logs only; never released.
# setup-php invokes the downloaded php-darwin installer through run_script.
bash() {
  local status install_log
  if [ "${repo:-}" != php-darwin ] || [ "${1:-}" != /tmp/install.sh ]; then
    command bash "$@"
    return $?
  fi
  # CI can exercise a candidate installer against existing published archives
  # before changing any release. Keep the action and its inputs unchanged.
  if [ -n "${PHP_DARWIN_TEST_INSTALLER:-}" ]; then
    shift
    set -- "$PHP_DARWIN_TEST_INSTALLER" "$@"
  fi
  install_log="${RUNNER_TEMP:?}/php-darwin-setup-install.log"
  if command bash "$@" >> "$install_log" 2>&1; then status=0; else status=$?; fi
  cat "$install_log"
  return "$status"
}
