#!/usr/bin/env bash
# Stop the action if a published cache cannot satisfy the request. In this
# campaign, a cache failure must never fall through to compiling PHP.
bash() {
  local status=0 install_log module
  if [ "${repo:-}" != php-darwin ] || [ "${1:-}" != /tmp/install.sh ]; then
    command bash "$@"
    return $?
  fi
  install_log="${RUNNER_TEMP:?}/php-darwin-setup-install.log"
  command bash "$@" >> "$install_log" 2>&1 || status=$?
  cat "$install_log"
  if [ "$status" -ne 0 ]; then
    printf 'Published PHP cache failed; refusing source-build fallback\n' >&2
    exit "$status"
  fi
  module="$(php-config --extension-dir)/swoole.so"
  if [ ! -L "$module" ] || ! php -r 'exit(extension_loaded("swoole") ? 0 : 1);'; then
    printf 'Published Swoole cache is unavailable; refusing fallback installation\n' >&2
    exit 1
  fi
  case "$(readlink "$module")" in
    */var/php-darwin/extensions/*/modules/swoole.so) ;;
    *) printf 'Swoole did not use its private published cache\n' >&2; exit 1 ;;
  esac
}
