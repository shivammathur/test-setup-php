# Record the packaged installer's wall time while preserving the exit status
# and the action's own error handling.
bash() {
  if [[ "${repo:-}" == php-darwin && "${1:-}" == /tmp/install.sh ]]; then
    local started status
    started=$(date +%s)
    if command bash "$@" >> "$RUNNER_TEMP/php-darwin.log" 2>&1; then status=0; else status=$?; fi
    printf 'php-darwin elapsed_seconds=%d exit=%d\n' "$(( $(date +%s) - started ))" "$status" >> "$RUNNER_TEMP/php-darwin.log"
    return "$status"
  fi
  command bash "$@"
}
