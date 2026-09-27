#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-build-inputs-test.XXXXXX") || exit 1
trap 'rm -rf "$work_dir"' EXIT
formula="$work_dir/formula.rb"
baseline="$work_dir/baseline.rb"

write_formula() {
  cat > "$formula" <<EOF
class Fixture < Formula
  url "https://example.invalid/php-8.5.1.tar.xz"
  sha256 "$(printf '%064d' 1)"
  revision 1
  bottle do
    root_url "https://example.invalid/bottles"
    rebuild ${REBUILD:-0}
    sha256 arm64_golden_gate: "$(printf '%064d' "${NEW_BOTTLE:-2}")"
    sha256 arm64_tahoe:       "$(printf '%064d' 3)"
$(if [ "${SONOMA:-true}" = true ]; then
  printf '    sha256 arm64_sonoma:      "%064d"\n' "${ARM_BOTTLE:-4}"
fi)
$(if [ "${INTEL:-true}" = true ]; then
  printf '    sha256 cellar: :any_skip_relocation, sonoma: "%064d"\n' "${INTEL_BOTTLE:-5}"
fi)
    sha256 arm64_linux:       "$(printf '%064d' "${LINUX_BOTTLE:-6}")"
  end
  depends_on "libxml2"
  def install
    system "make", "install"
  end
end
EOF
}

project() {
  bash "$script_dir/../../build/formula-build-inputs.sh" "$formula" > "$work_dir/current" || exit 1
}
expect_same() {
  project
  cmp -s "$baseline" "$work_dir/current" || php_darwin_die "$1 invalidated unchanged cache inputs"
}
expect_changed() {
  project
  ! cmp -s "$baseline" "$work_dir/current" || php_darwin_die "$1 did not invalidate the cache"
}

write_formula
project
cp "$work_dir/current" "$baseline" || exit 1
NEW_BOTTLE=20 LINUX_BOTTLE=60 write_formula
expect_same 'newer macOS and Linux bottles'
ARM_BOTTLE=40 write_formula
expect_changed 'the ARM Sonoma bottle checksum'
INTEL_BOTTLE=50 write_formula
expect_changed 'the older compatible Intel bottle checksum'
REBUILD=1 write_formula
expect_changed 'a usable bottle rebuild'
SONOMA=false write_formula
expect_changed 'removal of the ARM Sonoma bottle'
write_formula
printf '  revision 2\n' >> "$formula"
expect_changed 'the formula revision/source'

# Both platforms must stay supported when no compatible bottle remains.
SONOMA=false INTEL=false write_formula
project
cp "$work_dir/current" "$baseline" || exit 1
! grep -q 'sha256 arm64_\|sha256 cellar:\|root_url\|rebuild' "$baseline" || \
  php_darwin_die 'a source build retained unrelated bottle inputs'
SONOMA=false INTEL=false NEW_BOTTLE=20 LINUX_BOTTLE=60 REBUILD=3 write_formula
expect_same 'bottle updates after ARM/Intel source fallback'
printf '  depends_on "new-dependency"\n' >> "$formula"
expect_changed 'a dependency change during source fallback'

# Saved source bottles do not depend on any upstream bottle checksums.
write_formula
bash "$script_dir/../../build/formula-build-inputs.sh" "$formula" source > "$work_dir/source-inputs" || exit 1
ARM_BOTTLE=40 INTEL_BOTTLE=50 REBUILD=3 write_formula
bash "$script_dir/../../build/formula-build-inputs.sh" "$formula" source > "$work_dir/new-source-inputs" || exit 1
cmp -s "$work_dir/source-inputs" "$work_dir/new-source-inputs" || \
  php_darwin_die 'upstream bottle metadata invalidated a reusable source bottle'

# An exact Intel bottle takes precedence over an older compatible bottle.
write_formula
sed '/    rebuild 0/a\
    sha256 sequoia: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"\
' "$formula" > "$formula.new" || exit 1
mv "$formula.new" "$formula" || exit 1
project
cp "$work_dir/current" "$baseline" || exit 1
sed 's/sonoma: "0/sonoma: "f/' "$formula" > "$formula.new" || exit 1
mv "$formula.new" "$formula" || exit 1
expect_same 'an unused older Intel bottle'

# Unknown Ruby bottle constructs must never silently discard build inputs.
write_formula
sed 's/    rebuild 0/    rebuild ENV.fetch("REBUILD")/' "$formula" > "$formula.new" || exit 1
mv "$formula.new" "$formula" || exit 1
project
cmp -s "$formula" "$work_dir/current" || php_darwin_die 'unknown bottle syntax was not retained verbatim'
printf 'Platform-specific bottle inputs and macOS 14 source fallback validation passed\n'
