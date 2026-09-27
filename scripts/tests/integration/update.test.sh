#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-update-test.XXXXXX") || \
  php_darwin_die 'could not create stable update test fixtures'
php_path="$work_dir/homebrew-php"
extensions_path="$work_dir/homebrew-extensions"
fake_bin="$work_dir/bin"
manifest="$work_dir/php-8.5-manifest.json"
assets_jsonl="$work_dir/assets.jsonl"
gh_log="$work_dir/gh.log"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$php_path/Formula" "$extensions_path/Abstract" "$extensions_path/Formula" "$fake_bin" || \
  php_darwin_die 'could not create stable update fixture directories'
while read -r build ts; do
  formula=$(php_darwin_formula 8.5 "$build" "$ts") || exit 1
  printf 'formula %s\n' "$formula" > "$php_path/Formula/$formula.rb" || \
    php_darwin_die "could not write the $formula fixture"
  printf '  bottle do\n    root_url "https://example.invalid/bottles"\n    sha256 arm64_sonoma: "%064d"\n  end\n' 1 \
    >> "$php_path/Formula/$formula.rb" || php_darwin_die 'could not write bottle fixtures'
done < <(php_darwin_configured_variants)
printf 'shared source\n' > "$extensions_path/Abstract/abstract-php-extension.rb" || \
  php_darwin_die 'could not write the shared extension fixture'
printf 'xdebug source\n' > "$extensions_path/Formula/xdebug@8.5.rb" || \
  php_darwin_die 'could not write the Xdebug fixture'
printf 'pcov source\n' > "$extensions_path/Formula/pcov@8.5.rb" || \
  php_darwin_die 'could not write the PCOV fixture'
printf 'unrelated source\n' > "$extensions_path/Formula/unrelated@8.5.rb" || \
  php_darwin_die 'could not write the unrelated extension fixture'
for extension in xdebug pcov; do
  printf '  bottle do\n    root_url "https://example.invalid/bottles"\n    sha256 arm64_sonoma: "%064d"\n  end\n' 1 \
    >> "$extensions_path/Formula/$extension@8.5.rb" || exit 1
done
for tap_path in "$php_path" "$extensions_path"; do
  git -C "$tap_path" init -q || exit 1
  git -C "$tap_path" add . || exit 1
  git -C "$tap_path" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm fixture || exit 1
done
php_commit=$(git -C "$php_path" rev-parse HEAD) || exit 1
extensions_commit=$(git -C "$extensions_path" rev-parse HEAD) || exit 1

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
destination=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    destination=$2
    shift 2
  else
    shift
  fi
done
cp "${PHP_DARWIN_TEST_MANIFEST:?}" "${destination:?}" || exit 1
printf '200'
EOF
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = api ]; then
  printf '%s\n' "${PHP_DARWIN_TEST_ACTIVE_RUNS:-}"
  exit 0
fi
printf '%s\n' "$*" >> "${PHP_DARWIN_TEST_GH_LOG:?}"
EOF
chmod 0755 "$fake_bin/curl" "$fake_bin/gh" || php_darwin_die 'could not prepare stable update fixtures'

write_manifest() {
  local extensions_hash=$2
  local php_hash=$1

  : > "$assets_jsonl" || return 1
  while read -r build ts; do
    while IFS= read -r arch; do
      jq -cn --arg architecture "$arch" --arg build "$build" \
        --arg name "$(php_darwin_asset 8.5 "$build" "$ts" "$arch")" \
        --arg thread_safety "$ts" --arg sha256 "$(printf '%064d' 0)" \
        --argjson minimum_macos "$(php_darwin_platform_value "$arch" minimum_macos)" \
        '{architecture:$architecture,build:$build,bytes:1,minimum_macos:$minimum_macos,
          name:$name,sha256:$sha256,thread_safety:$thread_safety}' >> "$assets_jsonl" || return 1
    done < <(php_darwin_platform_arches)
  done < <(php_darwin_configured_variants)
  jq -s --arg extensions_hash "$extensions_hash" \
    --arg extensions_commit "$extensions_commit" \
    --arg homebrew_commit "$php_commit" \
    --arg source_hash "$php_hash" '
    {schema:1,php_version:"8.5",php_semver:"8.5.1",php_src_commit:"",
     extensions_source_hash:$extensions_hash,homebrew_extensions_commit:$extensions_commit,
     homebrew_php_commit:$homebrew_commit,source_hash:$source_hash,assets:.}
  ' "$assets_jsonl" > "$manifest"
  node "$script_dir/../helpers/add-package-inputs.cjs" "$manifest" "$extensions_path" || exit 1
}

run_gate() {
  local expected_dispatches=$1
  local expected_architectures=${2:-}
  local active_runs=${3:-}

  : > "$gh_log" || php_darwin_die 'could not reset the stable update log'
  HOMEBREW_EXTENSIONS_PATH="$extensions_path" HOMEBREW_PHP_PATH="$php_path" ONLY_VERSION=8.5 \
    PHP_DARWIN_TEST_GH_LOG="$gh_log" PHP_DARWIN_TEST_MANIFEST="$manifest" \
    PHP_DARWIN_TEST_ACTIVE_RUNS="$active_runs" \
    GITHUB_REF_NAME=main GITHUB_REPOSITORY=shivammathur/php-darwin PATH="$fake_bin:$PATH" \
    bash "$script_dir/../../release/update.sh" >/dev/null || php_darwin_die 'stable update gate failed'
  [ "$(awk 'END { print NR+0 }' "$gh_log")" -eq "$expected_dispatches" ] || \
    php_darwin_die "stable update gate dispatched $expected_dispatches workflows unexpectedly"
  if [ -z "$active_runs" ]; then
    local required=true
    [ "$expected_dispatches" -ne 0 ] || required=false
    : > "$work_dir/freshness-output"
    HOMEBREW_EXTENSIONS_PATH="$extensions_path" HOMEBREW_PHP_PATH="$php_path" \
      PHP_DARWIN_MANIFEST_PATH="$manifest" PHP_VERSION=8.5 CHANNEL=stable PUBLISH=true FORCE=false \
      GITHUB_OUTPUT="$work_dir/freshness-output" bash "$script_dir/../../build/check-build-freshness.sh" >/dev/null || \
      php_darwin_die 'queued stable build freshness check failed'
    grep -Fxq "build-required=$required" "$work_dir/freshness-output" || \
      php_darwin_die 'queued stable freshness did not match the published inputs'
  fi
  if [ -n "$expected_architectures" ]; then
    grep -Fq -- "-f architectures=$expected_architectures" "$gh_log" || \
      php_darwin_die "stable update gate did not request $expected_architectures"
  fi
}

php_hash=$(HOMEBREW_PHP_PATH="$php_path" bash "$script_dir/../../lib/source-hash.sh" 8.5) || \
  php_darwin_die 'could not hash the stable PHP fixtures'
extensions_hash=$(HOMEBREW_EXTENSIONS_PATH="$extensions_path" \
  bash "$script_dir/../../build/extensions-source-hash.sh" 8.5) || \
  php_darwin_die 'could not hash the stable extension fixtures'
write_manifest "$php_hash" "$extensions_hash" || php_darwin_die 'could not write the current stable manifest'
run_gate 0

for controls in 'true true' 'false false'; do
  read -r force publish <<< "$controls"
  : > "$work_dir/freshness-output"
  PHP_VERSION=8.5 CHANNEL=stable FORCE="$force" PUBLISH="$publish" \
    GITHUB_OUTPUT="$work_dir/freshness-output" bash "$script_dir/../../build/check-build-freshness.sh" >/dev/null || exit 1
  grep -Fxq 'build-required=true' "$work_dir/freshness-output" || \
    php_darwin_die 'an explicit build was incorrectly skipped'
done

# Reproduce macOS 27 bottle additions and brew bottle alignment changes against
# an existing release with raw formula hashes. No republish/migration is needed.
for formula_file in "$php_path"/Formula/*.rb "$extensions_path"/Formula/*.rb; do
  awk '
    /sha256 arm64_sonoma:/ {
      print "    sha256 arm64_golden_gate: \"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\""
      sub(/arm64_sonoma: /, "arm64_sonoma:      ")
    }
    { print }
  ' "$formula_file" > "$formula_file.new" || exit 1
  mv "$formula_file.new" "$formula_file" || exit 1
done
run_gate 0

jq '.assets |= map(select(.architecture == "arm64"))' "$manifest" > "$manifest.arm" || \
  php_darwin_die 'could not write the ARM64-only stable manifest fixture'
mv "$manifest.arm" "$manifest" || php_darwin_die 'could not install the ARM64-only stable manifest fixture'
run_gate 0 '' $'in_progress\tCache stable PHP 8.5'
run_gate 1 x86_64
grep -Fq -- "-f homebrew-php-commit=$php_commit" "$gh_log" || \
  php_darwin_die 'stable platform completion did not pin the published homebrew-php commit'
grep -Fq -- "-f homebrew-extensions-commit=$extensions_commit" "$gh_log" || \
  php_darwin_die 'stable platform completion did not pin the published extension commit'
write_manifest "$php_hash" "$extensions_hash" || php_darwin_die 'could not restore the current stable manifest'

printf 'changed unrelated source\n' > "$extensions_path/Formula/unrelated@8.5.rb" || \
  php_darwin_die 'could not change the unrelated stable extension fixture'
run_gate 0

printf 'changed xdebug source\n' > "$extensions_path/Formula/xdebug@8.5.rb" || \
  php_darwin_die 'could not change the configured stable extension fixture'
run_gate 1 'arm64 x86_64'

extensions_hash=$(HOMEBREW_EXTENSIONS_PATH="$extensions_path" \
  bash "$script_dir/../../build/extensions-source-hash.sh" 8.5) || \
  php_darwin_die 'could not rehash the stable extension fixtures'
write_manifest "$php_hash" "$extensions_hash" || php_darwin_die 'could not refresh the stable manifest fixture'
printf 'changed php source\n' >> "$php_path/Formula/php.rb" || \
  php_darwin_die 'could not change the stable PHP formula fixture'
run_gate 1 'arm64 x86_64'

printf 'Stable update validation passed\n'
