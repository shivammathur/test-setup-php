#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-matrix-test.XXXXXX") || \
  php_darwin_die 'could not create the matrix test directory'
trap 'rm -rf "$work_dir"' EXIT

full_output="$work_dir/full.txt"
GITHUB_OUTPUT="$full_output" PHP_VERSION=8.5 CHANNEL=stable BUILDS='debug release' \
  TS='nts zts' ARCHITECTURES='arm64 x86_64' PUBLISH=true bash "$script_dir/../../build/get-matrix.sh" || \
  php_darwin_die 'full workflow matrix generation failed'
full_build=$(sed -n 's/^build-matrix=//p' "$full_output")
full_test=$(sed -n 's/^test-matrix=//p' "$full_output")
full_variants=$(sed -n 's/^variant-matrix=//p' "$full_output")
jq -e '
  .include == [
    {php:"8.5",arch:"arm64",runner:"macos-14",test_runners:["macos-14","macos-15","macos-26"]},
    {php:"8.5",arch:"x86_64",runner:"macos-15-intel",test_runners:["macos-15-intel","macos-26-intel"]}
  ]
' <<< "$full_build" >/dev/null || php_darwin_die 'full architecture matrix uses incorrect build runners'
jq -e '
  .include == [
    {build:"debug",ts:"nts"}, {build:"debug",ts:"zts"},
    {build:"release",ts:"nts"}, {build:"release",ts:"zts"}
  ]
' <<< "$full_variants" >/dev/null || php_darwin_die 'full variant matrix does not select four independent builds'
jq -e '
  .include == [
    {php:"8.5",arch:"arm64",runner:"macos-14"},
    {php:"8.5",arch:"arm64",runner:"macos-15"},
    {php:"8.5",arch:"arm64",runner:"macos-26"},
    {php:"8.5",arch:"x86_64",runner:"macos-15-intel"},
    {php:"8.5",arch:"x86_64",runner:"macos-26-intel"}
  ]
' <<< "$full_test" >/dev/null || php_darwin_die 'full test matrix does not cover every named macOS version'

for version in $(php_darwin_nightly_versions); do
  nightly_output="$work_dir/nightly-$version.txt"
  GITHUB_OUTPUT="$nightly_output" PHP_VERSION="$version" CHANNEL=nightly BUILDS='debug release' \
    TS='nts zts' ARCHITECTURES='arm64 x86_64' PUBLISH=true bash "$script_dir/../../build/get-matrix.sh" || \
    php_darwin_die "PHP $version nightly workflow matrix generation failed"
  nightly_build=$(sed -n 's/^build-matrix=//p' "$nightly_output")
  nightly_test=$(sed -n 's/^test-matrix=//p' "$nightly_output")
  nightly_variants=$(sed -n 's/^variant-matrix=//p' "$nightly_output")
  [ "$nightly_variants" = "$full_variants" ] || \
    php_darwin_die "PHP $version nightly variant matrix is incomplete"
  jq -e --arg version "$version" --argjson stable "$full_build" \
    '. == ($stable | .include[].php = $version)' <<< "$nightly_build" >/dev/null || \
    php_darwin_die "PHP $version nightly build matrix is incomplete"
  jq -e --arg version "$version" --argjson stable "$full_test" \
    '. == ($stable | .include[].php = $version)' <<< "$nightly_test" >/dev/null || \
    php_darwin_die "PHP $version nightly test matrix is incomplete"
done

target_output="$work_dir/target.txt"
GITHUB_OUTPUT="$target_output" PHP_VERSION=5.6 CHANNEL=stable BUILDS=debug TS=nts \
  ARCHITECTURES=x86_64 PUBLISH=false bash "$script_dir/../../build/get-matrix.sh" || \
  php_darwin_die 'targeted workflow matrix generation failed'
target_build=$(sed -n 's/^build-matrix=//p' "$target_output")
target_test=$(sed -n 's/^test-matrix=//p' "$target_output")
target_variants=$(sed -n 's/^variant-matrix=//p' "$target_output")
jq -e '.include == [{build:"debug",ts:"nts"}]' <<< "$target_variants" >/dev/null || \
  php_darwin_die 'targeted variant matrix builds unrequested variants'
jq -e '.include == [{php:"5.6",arch:"x86_64",runner:"macos-15-intel",test_runners:["macos-15-intel","macos-26-intel"]}]' \
  <<< "$target_build" >/dev/null || php_darwin_die 'targeted build matrix is invalid'
jq -e '
  .include == [
    {php:"5.6",arch:"x86_64",runner:"macos-15-intel"},
    {php:"5.6",arch:"x86_64",runner:"macos-26-intel"}
  ]
' <<< "$target_test" >/dev/null || php_darwin_die 'targeted test matrix is invalid'

partial_output="$work_dir/partial.txt"
HOMEBREW_PHP_COMMIT=0123456789abcdef0123456789abcdef01234567 \
  HOMEBREW_EXTENSIONS_COMMIT=89abcdef0123456789abcdef0123456789abcdef \
  GITHUB_OUTPUT="$partial_output" PHP_VERSION=8.5 CHANNEL=stable BUILDS='debug release' \
  TS='nts zts' ARCHITECTURES=x86_64 PUBLISH=true bash "$script_dir/../../build/get-matrix.sh" || \
  php_darwin_die 'partial-platform publish matrix generation failed'
partial_build=$(sed -n 's/^build-matrix=//p' "$partial_output")
partial_variants=$(sed -n 's/^variant-matrix=//p' "$partial_output")
[ "$partial_variants" = "$full_variants" ] || \
  php_darwin_die 'partial-platform publishing omitted build variants'
jq -e '.include == [{php:"8.5",arch:"x86_64",runner:"macos-15-intel",test_runners:["macos-15-intel","macos-26-intel"]}]' \
  <<< "$partial_build" >/dev/null || php_darwin_die 'partial-platform publish build matrix is invalid'
if HOMEBREW_PHP_COMMIT='' HOMEBREW_EXTENSIONS_COMMIT='' \
  GITHUB_OUTPUT="$work_dir/invalid-partial.txt" PHP_VERSION=8.5 CHANNEL=stable \
  BUILDS='debug release' TS='nts zts' ARCHITECTURES=x86_64 PUBLISH=true \
  bash "$script_dir/../../build/get-matrix.sh" >/dev/null 2>&1; then
  php_darwin_die 'partial-platform publishing was accepted without pinned release commits'
fi

selected_output="$work_dir/selected.txt"
GITHUB_OUTPUT="$selected_output" PHP_VERSION=8.7 CHANNEL=nightly BUILDS=release \
  TS='zts nts' ARCHITECTURES=arm64 PUBLISH=false bash "$script_dir/../../build/get-matrix.sh" || \
  php_darwin_die 'selected variant matrix generation failed'
selected_variants=$(sed -n 's/^variant-matrix=//p' "$selected_output")
jq -e '.include == [{build:"release",ts:"zts"},{build:"release",ts:"nts"}]' \
  <<< "$selected_variants" >/dev/null || php_darwin_die 'selected variants or their requested order changed'
for invalid_builds in 'release release' 'release invalid'; do
  if GITHUB_OUTPUT="$work_dir/invalid-variants.txt" PHP_VERSION=8.7 CHANNEL=nightly \
    BUILDS="$invalid_builds" TS=nts PUBLISH=false \
    bash "$script_dir/../../build/get-matrix.sh" >/dev/null 2>&1; then
    php_darwin_die 'duplicate or invalid build variants were accepted'
  fi
done
if GITHUB_OUTPUT="$work_dir/incomplete-publish.txt" PHP_VERSION=8.7 CHANNEL=nightly \
  BUILDS=release TS=nts ARCHITECTURES='arm64 x86_64' PUBLISH=true \
  bash "$script_dir/../../build/get-matrix.sh" >/dev/null 2>&1; then
  php_darwin_die 'publishing was accepted without all four variants'
fi

while read -r runner expected_arch extra; do
  [ -n "$runner" ] || continue
  [ -z "$extra" ] || php_darwin_die "invalid compatibility-test fixture: $runner $expected_arch $extra"
  runner_output="$work_dir/runner-$runner.txt"
  RUNNER="$runner" GITHUB_OUTPUT="$runner_output" bash "$script_dir/../helpers/get-test-target.sh" || \
    php_darwin_die "could not resolve compatibility-test runner $runner"
  [ "$(sed -n 's/^arch=//p' "$runner_output")" = "$expected_arch" ] || \
    php_darwin_die "compatibility-test runner $runner resolved to the wrong architecture"
done <<'RUNNERS'
macos-14 arm64
macos-15 arm64
macos-26 arm64
macos-latest arm64
macos-15-intel x86_64
macos-26-intel x86_64
RUNNERS

printf 'Workflow matrix validation passed (8 variant builds, 5 compatibility tests, partial publishing)\n'
