#!/usr/bin/env bash
set -e
src="${SETUP_PHP_SOURCE:-setup-php}/src"
# shellcheck source=/dev/null
source "$src/scripts/extensions/add_extensions.sh"
get() { cat evidence/allreleases.xml; }
selected=$(get_pecl_version "$EXTENSION" "$EXPECTED_STATE")
printf '%s-%s resolved to %s\n' "$EXTENSION" "$EXPECTED_STATE" "$selected"
test "$selected" = "$EXPECTED_VERSION"
