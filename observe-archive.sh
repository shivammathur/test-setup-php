# setup-php suppresses the public installer's output. Save its diagnostics and
# hash the archive it hands to the packaged installer before staging is removed.
case "$0" in
  /tmp/install.sh)
    if [[ "${1:-}" == "$PHP_SERIES" && "${2:-}" == "$EXPECTED_BUILD" && "${3:-}" == "$phpts" ]]; then
      exec >> "$RUNNER_TEMP/php-darwin-install.log" 2>&1
    fi
    ;;
  */php-darwin-bootstrap.*/install.sh)
    if [[ -f "${4:-}" && "${1:-}" == "$PHP_SERIES" && "${2:-}" == "$EXPECTED_BUILD" && "${3:-}" == "$phpts" ]]; then
      shasum -a 256 "$4" > "$RUNNER_TEMP/php-darwin-archive.sha256"
    fi
    ;;
esac
