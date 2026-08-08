#!/usr/bin/env bash

set -euo pipefail

workspace="${GITHUB_WORKSPACE:?}"
results="$workspace/results"
work="${RUNNER_TEMP:?}/php-apple-clang-comparison"
test_id="${TEST_ID:?}"
test_label="${TEST_LABEL:?}"
formula_source="${FORMULA_SOURCE:?}"
formula_name="${FORMULA_NAME:?}"
formula_file="${FORMULA_FILE:?}"
php_series="${PHP_SERIES:?}"

mkdir -p "$results" "$work/bin" "$work/logs" "$work/bench" "$work/php-state"

{
  uname -a
  uname -m
  sw_vers
  system_profiler SPHardwareDataType
  sysctl -a | grep -E 'machdep.cpu|hw.(logicalcpu|physicalcpu|memsize)' || true
  brew config
  xcodebuild -version
  xcrun clang --version
} >"$results/environment.txt" 2>&1

if [[ "$(uname -m)" != arm64 ]]; then
  echo "This comparison requires a native Apple Silicon runner" >&2
  exit 1
fi

cat >"$work/flag-check.c" <<'EOF'
int main(void) { return 0; }
EOF
xcrun clang -O2 -Werror -mno-outline -Xclang -fno-split-cold-code \
  -c "$work/flag-check.c" -o "$work/flag-check.o"

brew install hyperfine

case "$formula_source" in
  tap)
    brew tap shivammathur/php
    brew trust shivammathur/php
    formula_repo="$(brew --repo shivammathur/php)"
    git -C "$formula_repo" fetch --depth=1 origin "${TAP_COMMIT:?}"
    git -C "$formula_repo" checkout --detach "${TAP_COMMIT:?}"
    test "$(git -C "$formula_repo" rev-parse HEAD)" = "$TAP_COMMIT"
    git -C "$formula_repo" show -s --format='%H%n%ci%n%s' HEAD >"$results/formula-commit.txt"
    ;;
  core)
    brew tap --force homebrew/core
    core_repo="$(brew --repo homebrew/core)"
    git -C "$core_repo" status --short >"$results/core-preexisting-changes.txt"
    if [[ -s "$results/core-preexisting-changes.txt" ]]; then
      git -C "$core_repo" stash push --include-untracked --message php-apple-clang-test
    fi
    git -C "$core_repo" fetch --depth=1 origin "${CORE_COMMIT:?}"
    git -C "$core_repo" checkout --detach "${CORE_COMMIT:?}"
    test "$(git -C "$core_repo" rev-parse HEAD)" = "$CORE_COMMIT"
    git -C "$core_repo" show -s --format='%H%n%ci%n%s' HEAD >"$results/formula-commit.txt"

    # Keep dependencies on Homebrew's API. The runner's bundled Homebrew is
    # older than install-step DSL calls already used by unrelated core formulae.
    brew tap-new --no-git local/core-php-test
    brew trust local/core-php-test
    formula_repo="$(brew --repo local/core-php-test)"
    formula_file="Formula/php.rb"
    formula_name="local/core-php-test/php"
    cp "$core_repo/Formula/p/php.rb" "$formula_repo/$formula_file"
    ruby -e '
      path = ARGV.fetch(0)
      contents = File.read(path)
      File.write(path, contents.sub(%q{ENV["PHP_BUILD_PROVIDER"] = tap.user}, %q{ENV["PHP_BUILD_PROVIDER"] = "Homebrew"}))
    ' "$formula_repo/$formula_file"
    git -C "$formula_repo" init --initial-branch=main
    git -C "$formula_repo" config user.name test-setup-php
    git -C "$formula_repo" config user.email test-setup-php@users.noreply.github.com
    git -C "$formula_repo" add .
    git -C "$formula_repo" commit -m 'Add Homebrew-core PHP formula'
    ;;
  *)
    echo "Unknown formula source: $formula_source" >&2
    exit 2
    ;;
esac

formula_path="$formula_repo/$formula_file"
test -f "$formula_path"
brew info --json=v2 "$formula_name" >"$results/formula-info.json"

cp "$formula_repo/Scripts/pgo_script.php" "$work/bench/pgo_script.php" 2>/dev/null || \
  curl --fail --location --retry 3 \
    --output "$work/bench/pgo_script.php" \
    "https://raw.githubusercontent.com/shivammathur/homebrew-php/${TAP_COMMIT}/Scripts/pgo_script.php"
cp "$workspace/scripts/untrained_extensions.php" "$work/bench/untrained_extensions.php"
curl --fail --location --retry 3 \
  --output "$work/bench/phpstan.phar" \
  https://github.com/phpstan/phpstan/releases/download/2.2.8/phpstan.phar
git clone --filter=blob:none https://github.com/nikic/PHP-Parser.git "$work/bench/PHP-Parser"
git -C "$work/bench/PHP-Parser" checkout fbd47f7ebcbb450138d92642a0a53b72a5285dda
curl --fail --location --retry 3 \
  --output "$work/bench/bench.php" \
  https://raw.githubusercontent.com/php/php-src/php-8.5.9/Zend/bench.php

printf 'variant\tbuild_seconds\n' >"$results/build-times.tsv"
printf 'variant\tcli_bytes\tpayload_bytes\tbottle_bytes\tphp_sha256\tbottle_sha256\n' >"$results/sizes.tsv"
printf 'variant\toutlined_symbols\tcold_symbols\n' >"$results/symbols.tsv"

stash_php_state() {
  local label="$1"
  local state_dir="$work/php-state/$label"
  local config_dir="$HOMEBREW_PREFIX/etc/php/$php_series"
  local log_file="$HOMEBREW_PREFIX/var/log/php-fpm.log"

  mkdir -p "$state_dir"
  if [[ -d "$config_dir" ]]; then
    mv "$config_dir" "$state_dir/php-$php_series"
  fi
  if [[ -e "$log_file" ]]; then
    mv "$log_file" "$state_dir/php-fpm.log"
  fi
}

build_variant() {
  local variant="$1"
  local variant_results="$results/$variant"
  local install_log="$work/logs/install-$variant.log"
  local start_time end_time build_seconds prefix bottle
  local cli_size payload_size bottle_size php_sha bottle_sha outlined cold

  mkdir -p "$variant_results"
  brew uninstall --force "$formula_name" >/dev/null 2>&1 || true
  stash_php_state "before-$variant-source"

  start_time="$(date +%s)"
  brew install --verbose --build-bottle "$formula_name" 2>&1 | tee "$install_log"
  end_time="$(date +%s)"
  build_seconds="$((end_time - start_time))"
  printf '%s\t%s\n' "$variant" "$build_seconds" >>"$results/build-times.tsv"

  if [[ "$variant" = optimized ]]; then
    grep -q -- '-mno-outline' "$install_log"
    grep -q -- '-fno-split-cold-code' "$install_log"
    {
      grep -- '-mno-outline' "$install_log" || true
      grep -- '-fno-split-cold-code' "$install_log" || true
    } | sed -n '1,80p' >"$variant_results/compiler-flags.log"
  else
    if grep -q -E -- '-mno-outline|-fno-split-cold-code' "$install_log"; then
      echo "Baseline unexpectedly used the Apple Clang optimization flags" >&2
      exit 1
    fi
  fi

  prefix="$(brew --prefix "$formula_name")"
  prefix="$(ruby -e 'puts File.realpath(ARGV.fetch(0))' "$prefix")"
  cp "$prefix/bin/php" "$work/bin/php-$variant"
  chmod +x "$work/bin/php-$variant"

  "$work/bin/php-$variant" -n -v >"$variant_results/php-version.txt"
  "$work/bin/php-$variant" -n -m >"$variant_results/php-modules.txt"
  file "$prefix/bin/php" >"$variant_results/php-file.txt"
  otool -L "$prefix/bin/php" >"$variant_results/php-linkage.txt"
  size -m "$prefix/bin/php" >"$variant_results/php-segments.txt" 2>&1 || true
  nm -a "$prefix/bin/php" 2>/dev/null | \
    grep -E 'OUTLINED_FUNCTION_|\.cold(\.|$)' >"$variant_results/php-special-symbols.txt" || true

  outlined="$(grep -c 'OUTLINED_FUNCTION_' "$variant_results/php-special-symbols.txt" || true)"
  cold="$(grep -Ec '\.cold(\.|$)' "$variant_results/php-special-symbols.txt" || true)"
  printf '%s\t%s\t%s\n' "$variant" "$outlined" "$cold" >>"$results/symbols.tsv"

  brew linkage --test "$formula_name" 2>&1 | tee "$variant_results/linkage.log"
  brew test "$formula_name" 2>&1 | tee "$variant_results/formula-test.log"

  (
    cd "$variant_results"
    brew bottle --json "$formula_name" 2>&1 | tee bottle.log
  )
  bottle="$(find "$variant_results" -maxdepth 1 -type f -name '*.bottle*.tar.gz' -print -quit)"
  test -n "$bottle"
  tar -tzf "$bottle" >"$variant_results/bottle-contents.txt"
  grep -q '/bin/php$' "$variant_results/bottle-contents.txt"

  cli_size="$(stat -f '%z' "$prefix/bin/php")"
  payload_size="$(find "$prefix" -type f -exec stat -f '%z' {} + | awk '{ total += $1 } END { printf "%.0f\n", total }')"
  bottle_size="$(stat -f '%z' "$bottle")"
  php_sha="$(shasum -a 256 "$prefix/bin/php" | awk '{print $1}')"
  bottle_sha="$(shasum -a 256 "$bottle" | awk '{print $1}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$variant" "$cli_size" "$payload_size" "$bottle_size" "$php_sha" "$bottle_sha" \
    >>"$results/sizes.tsv"

  printf '%s\n' "$bottle" >"$work/bottle-$variant.path"
}

build_variant baseline
brew uninstall --force "$formula_name"
stash_php_state baseline-source

ruby "$workspace/scripts/enable-apple-clang-flags.rb" "$formula_path"
git -C "$formula_repo" diff -- "$formula_file" >"$results/formula-optimized.diff"
grep -q -- '-mno-outline' "$formula_path"
grep -q -- '-fno-split-cold-code' "$formula_path"

build_variant optimized

diff -u "$results/baseline/php-modules.txt" "$results/optimized/php-modules.txt" \
  >"$results/module-diff.txt"
comm -3 \
  <(sort "$results/baseline/bottle-contents.txt") \
  <(sort "$results/optimized/bottle-contents.txt") \
  >"$results/bottle-path-diff.txt"
test ! -s "$results/bottle-path-diff.txt"

benchmark_batch() {
  local suite="$1"
  local variant="$2"
  local batch="$3"
  local json="$results/benchmarks/${suite}-${variant}-${batch}.json"

  if [[ "$suite" = phpstan ]]; then
    hyperfine \
      --warmup 1 \
      --runs 1 \
      --ignore-failure \
      --export-json "$json" \
      "bash $workspace/scripts/run-benchmark.sh $suite $work/bin/php-$variant $work/bench"
  else
    hyperfine \
      --warmup 1 \
      --runs 1 \
      --export-json "$json" \
      "bash $workspace/scripts/run-benchmark.sh $suite $work/bin/php-$variant $work/bench"
  fi
}

mkdir -p "$results/benchmarks"
for variant in baseline optimized; do
  for suite in pgo-script pgo-script-opcache zend-bench untrained-extensions; do
    bash "$workspace/scripts/run-benchmark.sh" "$suite" "$work/bin/php-$variant" "$work/bench" \
      >"$results/benchmarks/preflight-$suite-$variant.txt"
  done

  set +e
  bash "$workspace/scripts/run-benchmark.sh" phpstan "$work/bin/php-$variant" "$work/bench" \
    >"$results/benchmarks/preflight-phpstan-$variant.txt" 2>&1
  phpstan_status=$?
  set -e
  if ((phpstan_status > 1)); then
    echo "PHPStan preflight failed with exit code $phpstan_status" >&2
    exit "$phpstan_status"
  fi
done

for suite in phpstan pgo-script pgo-script-opcache zend-bench untrained-extensions; do
  batch=0
  # Five measured samples per variant, in a balanced alternating order.
  for variant in \
    baseline optimized \
    optimized baseline \
    baseline optimized \
    optimized baseline \
    baseline optimized; do
    batch=$((batch + 1))
    benchmark_batch "$suite" "$variant" "$batch"
  done
done

"$work/bin/php-optimized" -n "$workspace/scripts/summarize.php" \
  "$test_id" "$test_label" "$results"

validate_bottle() {
  local variant="$1"
  local bottle

  bottle="$(<"$work/bottle-$variant.path")"
  brew uninstall --force "$formula_name" >/dev/null 2>&1 || true
  stash_php_state "before-$variant-bottle"
  HOMEBREW_DEVELOPER=1 brew install "$bottle" 2>&1 | tee "$results/$variant/bottle-install.log"
  brew linkage --test "$formula_name" 2>&1 | tee "$results/$variant/bottle-linkage.log"
  brew test "$formula_name" 2>&1 | tee "$results/$variant/bottle-formula-test.log"
}

validate_bottle baseline
validate_bottle optimized
