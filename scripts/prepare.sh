#!/usr/bin/env bash

runner_arch=$(uname -m) || exit 1
expected_arch=arm64
case "${RUNNER_LABEL:?}" in
  *-intel) expected_arch=x86_64 ;;
esac
printf 'Runner label %s resolved to %s\n' "$RUNNER_LABEL" "$runner_arch"
[ "$runner_arch" = "$expected_arch" ] || exit 1

tap_json=$(brew tap-info --installed --json=v1) || exit 1
unused_taps=()
while IFS= read -r installed_tap; do
  case "$installed_tap" in
    homebrew/core|homebrew/cask|shivammathur/php) ;;
    *) [ -n "$installed_tap" ] && unused_taps+=("$installed_tap") ;;
  esac
done < <(printf '%s\n' "$tap_json" | jq -r '.[].name')
if [ "${#unused_taps[@]}" -gt 0 ]; then
  tap_log=$(mktemp "${RUNNER_TEMP:?}/php-darwin-taps.XXXXXX") || exit 1
  if ! brew untap --force "${unused_taps[@]}" > "$tap_log" 2>&1; then
    cat "$tap_log"
    exit 1
  fi
  rm -f "$tap_log"
fi

installed_php_formulae=()
while IFS= read -r installed_formula; do
  if [[ "$installed_formula" =~ ^php(@[0-9]+\.[0-9]+)?(-debug)?(-zts)?$ ]]; then
    installed_php_formulae+=("$installed_formula")
  fi
done < <(brew list --formula)
if [ "${#installed_php_formulae[@]}" -gt 0 ]; then
  brew uninstall --force --ignore-dependencies "${installed_php_formulae[@]}" || exit 1
fi
if brew list --formula | grep -Eq '^php(@[0-9]+\.[0-9]+)?(-debug)?(-zts)?$'; then
  printf 'A Homebrew PHP formula remained before setup-php\n' >&2
  exit 1
fi

brew_prefix=$(brew --prefix) || exit 1
sentinel="$brew_prefix/etc/php-darwin-preserve-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
printf 'preserve-existing-homebrew-state\n' > "$sentinel" || exit 1
chmod 0444 "$sentinel" || exit 1
printf "PHP_DARWIN_SENTINEL=%s\n" "$sentinel" >> "${GITHUB_ENV:?}"
if brew list --versions hello >/dev/null 2>&1; then
  printf 'PHP_DARWIN_HELLO_PREEXISTED=true\n' >> "$GITHUB_ENV"
else
  printf 'PHP_DARWIN_HELLO_PREEXISTED=false\n' >> "$GITHUB_ENV"
fi
