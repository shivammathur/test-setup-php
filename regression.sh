#!/usr/bin/env bash
set -e
source "${1:-src/scripts/extensions/add_extensions.sh}"
checks=0
get() { printf '%s\n' "$fixture"; }
assert_version() {
  local actual
  actual=$(get_pecl_version example "$1" "${3:-[0-9]+}")
  if [ "$actual" != "$2" ]; then
    printf 'FAIL: stability=%s major=%s expected=%s actual=%s\n' "$1" "${3:-any}" "$2" "$actual" >&2
    exit 1
  fi
  checks=$((checks + 1))
}
fixture=$(cat "$(dirname "${BASH_SOURCE[0]}")/fixtures/ev.xml")
for stability in stable rc preview beta alpha devel snapshot BETA RC; do
  assert_version "$stability" 1.2.3
done
fixture='<r><v>2.0.0dev1</v><s>devel</s></r>
<r><v>1.9.0alpha1</v><s>alpha</s></r>
<r><v>1.8.0beta1</v><s>beta</s></r>
<r><v>1.7.0preview1</v><s>devel</s></r>
<r><v>1.6.0RC1</v><s>beta</s></r>
<r><v>1.5.0</v><s>stable</s></r>'
assert_version stable 1.5.0
assert_version rc 1.6.0RC1
assert_version preview 1.7.0preview1
assert_version beta 1.8.0beta1
assert_version alpha 1.9.0alpha1
assert_version devel 2.0.0dev1
assert_version snapshot 2.0.0dev1
assert_version BETA 1.8.0beta1
assert_version RC 1.6.0RC1
# Numeric releases may be unstable: never fall back to one below the requested minimum.
fixture='<r><v>2.0.0</v><s>alpha</s></r>
<r><v>1.9.0b2</v><s>beta</s></r>'
assert_version beta 1.9.0b2
assert_version alpha 2.0.0
assert_version stable ''
assert_version rc ''
fixture='<r><v>1.3</v><s>stable</s></r>
<r><v>1.2beta1</v><s>beta</s></r>'
assert_version stable 1.3
assert_version beta 1.3
fixture='<r><v>1.3beta2</v><s>beta</s></r>
<r><v>1.2</v><s>stable</s></r>'
assert_version stable 1.2
assert_version beta 1.3beta2
fixture='<r><v>6.0.0</v><s>stable</s></r>
<r><v>5.4.0beta1</v><s>beta</s></r>
<r><v>5.3.0</v><s>stable</s></r>
<r><v>4.8.0</v><s>stable</s></r>'
assert_version stable 5.3.0 5
assert_version beta 5.4.0beta1 5
assert_version stable 4.8.0 4
assert_version beta '' 3
fixture='<r><v>1.0.0</v><s>snapshot</s></r>'
for stability in stable rc preview beta alpha devel; do assert_version "$stability" ''; done
assert_version snapshot 1.0.0
fixture=''
assert_version beta ''
fixture='<html>404 not found</html>'
assert_version beta ''
# A missing acceptable release must not fall through to an unconstrained install.
cross=FAIL
add_log() { printf '%s %s %s\n' "$@"; }
output=$(
  add_pecl_extension() { echo 'unexpected install'; }
  add_unstable_extension example beta extension
)
[[ "$output" == *'No release found with minimum stability beta'* && "$output" != *'unexpected install'* ]]
checks=$((checks + 1))
# Exact pins must not become minimum-stability requests; preserve canonical RC spelling.
fixture='<r><v>9.9.9</v><s>stable</s></r>
<r><v>1.2.3RC1</v><s>beta</s></r>
<r><v>1.2.3beta1</v><s>beta</s></r>'
assert_version 1.2.3rc1 1.2.3RC1
assert_version 1.2.3RC1 1.2.3RC1
assert_version 1.2.3beta1 1.2.3beta1
assert_version 0.0.1beta9 0.0.1beta9
(
  set +e
  ext_dir=$(mktemp -d)
  trap 'rm -rf "$ext_dir"' EXIT
  fail_fast=true
  semver=8.5.0
  tick=PASS
  check_extension() { return 1; }
  enable_extension() { :; }
  sudo() { "$@"; }
  php() { [ -f "$ext_dir/installed" ] && cat "$ext_dir/installed"; return 0; }
  pecl_install() { printf '%s' "${1#example-}" > "$ext_dir/installed"; }
  for pin in 1.2.3beta1 1.2.3alpha2 1.2.3rc1 1.2.3RC1 1.2.3preview1 1.2.3snapshot1 1.2.3devel1; do
    rm -f "$ext_dir/installed"
    add_pecl_extension example "$pin" extension > /dev/null
    expected=$pin
    [ "$pin" = 1.2.3rc1 ] && expected=1.2.3RC1
    [ "$(cat "$ext_dir/installed")" = "$expected" ] || exit 1
  done
) || exit 1
checks=$((checks + 7))
printf 'PASS: %s resolver/install checks on Bash %s\n' "$checks" "$BASH_VERSION"
