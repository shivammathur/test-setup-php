#!/usr/bin/env bash

brew config || exit 1
brew cleanup --dry-run >/dev/null 2>&1 || exit 1
[ "$(< "${PHP_DARWIN_SENTINEL:?}")" = preserve-existing-homebrew-state ] || exit 1
[ "$(stat -f "%Lp" "$PHP_DARWIN_SENTINEL")" = 444 ] || exit 1

brew fetch --retry hello || exit 1
[ "${PHP_DARWIN_HELLO_PREEXISTED:?}" = true ] || brew install hello || exit 1
"$(brew --prefix hello)/bin/hello" | grep -F "Hello, world!" || exit 1
[ "$PHP_DARWIN_HELLO_PREEXISTED" = true ] || brew uninstall --force hello || exit 1

doctor_log=$(mktemp "${RUNNER_TEMP:?}/php-darwin-brew-doctor.XXXXXX") || exit 1
if ! brew doctor > "$doctor_log" 2>&1; then
  if grep -Eq '^(Error:|.*broken)' "$doctor_log"; then
    cat "$doctor_log"
    exit 1
  fi
fi
rm -f "$doctor_log"
