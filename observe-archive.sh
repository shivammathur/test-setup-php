# Record what stock setup-php passes to the published installer. Keep its exit
# status and preserve the diagnostics that setup-php normally redirects.
bash() {
  local observed status
  case "${1:-}" in
    /tmp/install.sh)
      if [[ "${repo:-}" == php-darwin ]]; then
        command bash "$@" >> "$RUNNER_TEMP/php-darwin-install.log" 2>&1
        return $?
      fi
      ;;
    */php-darwin-bootstrap.*/install.sh)
      if [[ "${2:-}" == "$PHP_SERIES" && "${3:-}" == "$EXPECTED_BUILD" && "${4:-}" == "$phpts" && -f "${5:-}" ]]; then
        observed=$(shasum -a 256 "$5") || return 1
        if command bash "$@"; then status=0; else status=$?; fi
        if [[ "$status" == 0 ]]; then
          printf '%s\n' "$observed" > "$RUNNER_TEMP/php-darwin-archive.sha256"
        fi
        return "$status"
      fi
      ;;
  esac
  command bash "$@"
}
