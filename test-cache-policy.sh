#!/usr/bin/env bash
source_file=${1:?}
work_dir=$(mktemp -d) || exit 1
trap 'rm -rf "$work_dir"' EXIT
export POLICY_SOURCE="$source_file"
export POLICY_LOG="$work_dir/events"

for scenario in intel-failure arm-fallback intel-success disabled self-hosted install-failure upgrade-failure; do
  : > "$POLICY_LOG"
  bash -s "$scenario" <<'BASH'
eval "$(sed '/^# Variables/,$d' "$POLICY_SOURCE")"
scenario=$1
version=8.3 debug=release ts=nts runner=github php_tap=shivammathur/homebrew-php cross=FAIL
uname() { if [ "$scenario" = arm-fallback ]; then echo arm64; else echo x86_64; fi; }
setup_cached_versions() { echo cache >> "$POLICY_LOG"; [ "$scenario" = intel-success ]; }
update_dependencies() { echo update >> "$POLICY_LOG"; }
add_brew_tap() { echo tap >> "$POLICY_LOG"; }
safe_brew() { echo brew >> "$POLICY_LOG"; }
brew() {
  if [ "$1" = info ]; then echo '[{"versions":{"stable":"8.3.2"}}]'; else echo link >> "$POLICY_LOG"; fi
}
case "$scenario" in
  disabled) use_package_cache=false ;;
  self-hosted) runner=self-hosted ;;
  install-failure|upgrade-failure)
    step_log() { :; }
    check_pre_installed() { :; }
    get_brewed_php() { if [ "$scenario" = install-failure ]; then echo false; else echo 8.3.1; fi; }
    add_log() { echo "$*" >> "$POLICY_LOG"; }
    old_versions='^[2-5]\.[0-5]$'
    setup_php
    exit 99
    ;;
esac
add_php install false
BASH
  result=$?
  case "$scenario" in
    intel-failure|install-failure|upgrade-failure)
      [ "$result" -eq 1 ] || exit 1
      ! grep -Eq '^(update|tap|brew|link)$' "$POLICY_LOG" || exit 1
      ;;
    intel-success)
      [ "$result" -eq 0 ] && [ "$(cat "$POLICY_LOG")" = cache ] || exit 1
      ;;
    arm-fallback|disabled|self-hosted)
      [ "$result" -eq 0 ] && grep -qx brew "$POLICY_LOG" || exit 1
      ;;
  esac
  case "$scenario" in install-failure|upgrade-failure) grep -q '^FAIL PHP Could not' "$POLICY_LOG" || exit 1 ;; esac
  printf 'PASS %s\n' "$scenario"
done
