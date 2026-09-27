#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$script_dir/../.." && pwd)
cd "$root"
# shellcheck source=scripts/lib/lib.sh
. "$root/scripts/lib/lib.sh"

check() {
  if command -v brew >/dev/null 2>&1; then php_darwin_select_ruby; fi
  while IFS= read -r -d '' file; do
    case "$file" in
      *.sh|*.sh.in) bash -n "$file" ;;
      *.cjs) node --check "$file" ;;
      *.rb) "${PHP_DARWIN_RUBY:-ruby}" -c "$file" >/dev/null ;;
    esac
  done < <(find scripts .github/actions templates -type f -print0)
  bash "$script_dir/integration/configuration.test.sh"
  bash "$root/scripts/installer/validate-install.sh"
}

suite() {
  local name=$1 file version
  node --test "$script_dir/$name/"*.test.cjs
  for file in "$script_dir/$name/"*.test.sh; do
    [ -f "$file" ] || continue
    case "${file##*/}" in
      configuration.test.sh) continue ;;
      update-nightly.test.sh)
        for version in $(php_darwin_nightly_versions); do bash "$file" "$version"; done ;;
      *) bash "$file" ;;
    esac
  done
}

case "${1:-all}" in
  check) check ;;
  unit|integration) check; suite "$1" ;;
  all) check; suite unit; suite integration ;;
  *) printf 'Usage: %s [check|unit|integration|all]\nNative and end-to-end suites run through GitHub Actions; see docs/maintenance.md.\n' "$0" >&2; exit 2 ;;
esac
