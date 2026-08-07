#!/usr/bin/env bash

set -euo pipefail

workspace="${GITHUB_WORKSPACE:?}"
results="$workspace/results"
work="${RUNNER_TEMP:?}/php-pgo-comparison"
tap_commit="${TAP_COMMIT:?}"
architecture="${TEST_ARCHITECTURE:?}"

mkdir -p "$results" "$work/bin" "$work/logs" "$work/bench"

{
  uname -a
  lscpu
  brew config
  gcc --version
} >"$results/environment.txt" 2>&1

brew tap shivammathur/php
brew trust shivammathur/php
tap_repo="$(brew --repo shivammathur/php)"
git -C "$tap_repo" fetch --depth=1 origin "$tap_commit"
git -C "$tap_repo" checkout --detach "$tap_commit"
test "$(git -C "$tap_repo" rev-parse HEAD)" = "$tap_commit"

cp "$tap_repo/Scripts/pgo_script.php" "$work/bench/pgo_script.php"
cp "$workspace/scripts/untrained_extensions.php" "$work/bench/untrained_extensions.php"

brew install hyperfine
curl --fail --location --retry 3 \
  --output "$work/bench/phpstan.phar" \
  https://github.com/phpstan/phpstan/releases/download/2.2.8/phpstan.phar
git clone --filter=blob:none https://github.com/nikic/PHP-Parser.git "$work/bench/PHP-Parser"
git -C "$work/bench/PHP-Parser" checkout fbd47f7ebcbb450138d92642a0a53b72a5285dda
curl --fail --location --retry 3 \
  --output "$work/bench/bench.php" \
  https://raw.githubusercontent.com/php/php-src/php-8.5.9/Zend/bench.php

printf 'variant\tcli_bytes\tpayload_bytes\tbottle_bytes\tphp_sha256\n' >"$results/sizes.tsv"

stash_php_state() {
  local label="$1"
  local state_dir="$work/php-state/$label"
  local config_dir="$HOMEBREW_PREFIX/etc/php/8.5"
  local log_file="$HOMEBREW_PREFIX/var/log/php-fpm.log"

  mkdir -p "$state_dir"
  if [[ -d "$config_dir" ]]; then
    mv "$config_dir" "$state_dir/php-8.5"
  fi
  if [[ -e "$log_file" ]]; then
    mv "$log_file" "$state_dir/php-fpm.log"
  fi
}

build_variant() {
  local variant="$1"
  local variant_results="$results/$variant"
  local install_log="$work/logs/install-$variant.log"
  local prefix bottle cli_size payload_size bottle_size php_sha

  mkdir -p "$variant_results"
  brew install --verbose --build-bottle shivammathur/php/php 2>&1 | tee "$install_log"

  if [[ "$variant" = partial ]]; then
    grep -q -- '-fprofile-partial-training' "$install_log"
  elif grep -q -- '-fprofile-partial-training' "$install_log"; then
    echo "Baseline unexpectedly used -fprofile-partial-training" >&2
    exit 1
  fi

  grep -E -- '-f(profile-(generate|use|correction|partial-training)|no-tracer)' \
    "$install_log" >"$variant_results/profile-flags.log" || true

  prefix="$(realpath "$(brew --prefix shivammathur/php/php)")"
  cp "$prefix/bin/php" "$work/bin/php-$variant"
  chmod +x "$work/bin/php-$variant"

  "$work/bin/php-$variant" -n -v >"$variant_results/php-version.txt"
  "$work/bin/php-$variant" -n -m >"$variant_results/php-modules.txt"
  file "$prefix/bin/php" >"$variant_results/php-file.txt"
  readelf -n "$prefix/bin/php" >"$variant_results/php-notes.txt" 2>&1 || true

  brew linkage --test shivammathur/php/php 2>&1 | tee "$variant_results/linkage.log"
  brew test shivammathur/php/php 2>&1 | tee "$variant_results/formula-test.log"

  (
    cd "$variant_results"
    brew bottle --json shivammathur/php/php 2>&1 | tee bottle.log
  )
  bottle="$(find "$variant_results" -maxdepth 1 -type f -name '*.bottle*.tar.gz' -print -quit)"
  test -n "$bottle"
  tar -tzf "$bottle" >"$variant_results/bottle-contents.txt"
  grep -q '/bin/php$' "$variant_results/bottle-contents.txt"

  cli_size="$(stat --format='%s' "$prefix/bin/php")"
  payload_size="$(find "$prefix" -type f -printf '%s\n' | awk '{ total += $1 } END { printf "%.0f\n", total }')"
  bottle_size="$(stat --format='%s' "$bottle")"
  php_sha="$(sha256sum "$prefix/bin/php" | cut -d' ' -f1)"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$variant" "$cli_size" "$payload_size" "$bottle_size" "$php_sha" >>"$results/sizes.tsv"

  printf '%s\n' "$bottle" >"$work/bottle-$variant.path"
}

build_variant baseline
brew uninstall --force shivammathur/php/php
stash_php_state baseline-source

git -C "$tap_repo" apply "$workspace/patches/fprofile-partial-training.patch"
grep -q -- '-fprofile-partial-training' "$tap_repo/Formula/php.rb"
git -C "$tap_repo" diff -- Formula/php.rb >"$results/formula-partial-training.diff"

build_variant partial

diff -u "$results/baseline/php-modules.txt" "$results/partial/php-modules.txt" \
  >"$results/module-diff.txt"
comm -3 \
  <(sort "$results/baseline/bottle-contents.txt") \
  <(sort "$results/partial/bottle-contents.txt") \
  >"$results/bottle-path-diff.txt"
test ! -s "$results/bottle-path-diff.txt"

allowed_cpus="$(awk '/Cpus_allowed_list/ {print $2}' /proc/self/status)"
export BENCH_CPU="${allowed_cpus%%[-,]*}"
printf 'Allowed CPUs: %s\nBenchmark CPU: %s\n' "$allowed_cpus" "$BENCH_CPU" \
  >"$results/benchmark-cpu.txt"

benchmark_batch() {
  local suite="$1"
  local variant="$2"
  local batch="$3"
  local runs="$4"
  local json="$results/benchmarks/${suite}-${variant}-${batch}.json"
  local extra_options=()

  if [[ "$suite" = phpstan ]]; then
    extra_options+=(--ignore-failure)
  fi

  hyperfine \
    --warmup 1 \
    --runs "$runs" \
    "${extra_options[@]}" \
    --export-json "$json" \
    "$workspace/scripts/run-benchmark.sh $suite $work/bin/php-$variant $work/bench"
}

mkdir -p "$results/benchmarks"
for variant in baseline partial; do
  for suite in pgo-script zend-bench untrained-extensions; do
    "$workspace/scripts/run-benchmark.sh" "$suite" "$work/bin/php-$variant" "$work/bench" \
      >"$results/benchmarks/preflight-$suite-$variant.txt"
  done

  set +e
  "$workspace/scripts/run-benchmark.sh" phpstan "$work/bin/php-$variant" "$work/bench" \
    >"$results/benchmarks/preflight-phpstan-$variant.txt" 2>&1
  phpstan_status=$?
  set -e
  if ((phpstan_status > 1)); then
    echo "PHPStan preflight failed with exit code $phpstan_status" >&2
    exit "$phpstan_status"
  fi
done

for suite in phpstan pgo-script zend-bench untrained-extensions; do
  case "$suite" in
    phpstan) runs=3 ;;
    pgo-script) runs=5 ;;
    zend-bench) runs=10 ;;
    untrained-extensions) runs=5 ;;
  esac

  batch=0
  for variant in baseline partial partial baseline partial baseline baseline partial; do
    batch=$((batch + 1))
    benchmark_batch "$suite" "$variant" "$batch" "$runs"
  done
done

partial_php="$work/bin/php-partial"
"$partial_php" -n "$workspace/scripts/summarize.php" "$architecture" "$results"

validate_bottle() {
  local variant="$1"
  local bottle

  bottle="$(<"$work/bottle-$variant.path")"
  brew uninstall --force shivammathur/php/php >/dev/null 2>&1 || true
  stash_php_state "before-$variant-bottle"
  HOMEBREW_DEVELOPER=1 brew install "$bottle" 2>&1 | tee "$results/$variant/bottle-install.log"
  brew linkage --test shivammathur/php/php 2>&1 | tee "$results/$variant/bottle-linkage.log"
  brew test shivammathur/php/php 2>&1 | tee "$results/$variant/bottle-formula-test.log"
}

validate_bottle baseline
validate_bottle partial
