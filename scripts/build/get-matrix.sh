#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

php_version=${PHP_VERSION:?}
channel=${CHANNEL:?}
builds=${BUILDS:-debug release}
thread_safety=${TS:-nts zts}
architectures=${ARCHITECTURES:-arm64 x86_64}
publish=${PUBLISH:-false}
source_commit=${HOMEBREW_PHP_COMMIT:-}
extension_source_commit=${HOMEBREW_EXTENSIONS_COMMIT:-}

php_darwin_validate_channel "$php_version" "$channel"
read -r -a build_values <<< "$builds"
read -r -a ts_values <<< "$thread_safety"
read -r -a arch_values <<< "$architectures"
[ "${#build_values[@]}" -gt 0 ] || php_darwin_die 'at least one build type is required'
[ "${#ts_values[@]}" -gt 0 ] || php_darwin_die 'at least one thread-safety mode is required'
[ "${#arch_values[@]}" -gt 0 ] || php_darwin_die 'at least one architecture is required'

seen_builds=
for build in "${build_values[@]}"; do
  php_darwin_validate_build "$build"
  case " $seen_builds " in *" $build "*) php_darwin_die "duplicate build type: $build" ;; esac
  seen_builds="$seen_builds $build"
done
seen_ts=
for ts in "${ts_values[@]}"; do
  php_darwin_validate_ts "$ts"
  case " $seen_ts " in *" $ts "*) php_darwin_die "duplicate thread-safety mode: $ts" ;; esac
  seen_ts="$seen_ts $ts"
done
seen_arches=
for requested_arch in "${arch_values[@]}"; do
  normalized_arch=$(php_darwin_normalize_arch "$requested_arch") || exit 1
  case " $seen_arches " in *" $normalized_arch "*) php_darwin_die "duplicate architecture: $normalized_arch" ;; esac
  seen_arches="$seen_arches $normalized_arch"
done
case "$publish" in
  true)
    [ "${#build_values[@]}" -eq 2 ] && [ "${#ts_values[@]}" -eq 2 ] || \
      php_darwin_die 'publishing requires the complete build and thread-safety matrix'
    if [ "${#arch_values[@]}" -lt "$(php_darwin_platform_arches | awk 'END { print NR+0 }')" ]; then
      [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] && \
        [[ "$extension_source_commit" =~ ^[0-9a-f]{40}$ ]] || \
        php_darwin_die 'partial-platform publishing requires both existing release source commits'
    fi
    ;;
  false) ;;
  *) php_darwin_die "publish must be true or false: $publish" ;;
esac

work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-matrix.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
build_entries_file="$work_dir/build.jsonl"
test_entries_file="$work_dir/test.jsonl"
variant_entries_file="$work_dir/variants.jsonl"
: > "$build_entries_file"
: > "$test_entries_file"
: > "$variant_entries_file"
for build in "${build_values[@]}"; do
  for ts in "${ts_values[@]}"; do
    jq -cn --arg build "$build" --arg ts "$ts" '{build:$build,ts:$ts}' >> "$variant_entries_file" || \
      php_darwin_die 'could not create a build variant matrix entry'
  done
done
for requested_arch in "${arch_values[@]}"; do
  arch=$(php_darwin_normalize_arch "$requested_arch") || exit 1
  runner=$(php_darwin_platform_value "$arch" build_runner) || \
    php_darwin_die "build runner is not configured for $arch"
  test_runners=$(php_darwin_platform_value "$arch" test_runners | jq -c 'map(select(. != "macos-latest"))') || \
    php_darwin_die "test runners are not configured for $arch"
  jq -cn --arg php "$php_version" --arg arch "$arch" --arg runner "$runner" --argjson tests "$test_runners" \
    '{php:$php,arch:$arch,runner:$runner,test_runners:$tests}' >> "$build_entries_file"
  while IFS= read -r test_runner; do
    jq -cn --arg php "$php_version" --arg arch "$arch" --arg runner "$test_runner" \
      '{php:$php,arch:$arch,runner:$runner}' >> "$test_entries_file"
  done < <(jq -r '.[]' <<< "$test_runners")
done

build_matrix=$(jq -c --slurpfile include "$build_entries_file" '.include=$include' "$script_dir/../../templates/workflow-matrix.json") || \
  php_darwin_die 'could not create the build matrix'
test_matrix=$(jq -c --slurpfile include "$test_entries_file" '.include=$include' "$script_dir/../../templates/workflow-matrix.json") || \
  php_darwin_die 'could not create the test matrix'
variant_matrix=$(jq -c --slurpfile include "$variant_entries_file" '.include=$include' "$script_dir/../../templates/workflow-matrix.json") || \
  php_darwin_die 'could not create the build variant matrix'
printf 'build-matrix=%s\n' "$build_matrix" >> "${GITHUB_OUTPUT:?}" || php_darwin_die 'could not write the build matrix output'
printf 'test-matrix=%s\n' "$test_matrix" >> "${GITHUB_OUTPUT:?}" || php_darwin_die 'could not write the test matrix output'
printf 'variant-matrix=%s\n' "$variant_matrix" >> "${GITHUB_OUTPUT:?}" || php_darwin_die 'could not write the build variant matrix output'

if [ -n "${PHP_DARWIN_BUILD_PLAN:-}" ]; then
  jq -n --arg version "$php_version" --arg revision "${GITHUB_SHA:?}" \
    --slurpfile architectures "$build_entries_file" --slurpfile variants "$variant_entries_file" \
    --slurpfile tests "$test_entries_file" '
    {schema:1,php_version:$version,revision:$revision,
     builds:[$architectures[] as $a | $variants[] | {arch:$a.arch,build:.build,ts:.ts}],
     tests:[$tests[] | {arch,runner}]}
  ' > "$PHP_DARWIN_BUILD_PLAN" || exit 1
fi
