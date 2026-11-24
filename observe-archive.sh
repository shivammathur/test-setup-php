# Preserve the diagnostic output from the public php-darwin installer. The
# action normally redirects it to /dev/null. Run all commands with their
# original arguments and propagate their exit status.
bash() {
  if [[ "${repo:-}" == php-darwin && "${1:-}" == /tmp/install.sh ]]; then
    command bash "$@" >> "$RUNNER_TEMP/php-darwin-install.log" 2>&1
  else
    command bash "$@"
  fi
}
