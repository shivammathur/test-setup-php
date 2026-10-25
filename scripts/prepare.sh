#!/usr/bin/env bash
set -euo pipefail
mode=${1:?}
mkdir -p "$RUNNER_TEMP/evidence" "$RUNNER_TEMP/reference"
if [[ "$mode" = wait-darwin ]]; then
  deadline=$((SECONDS + 10800))
  while (( SECONDS < deadline )); do
    gh api repos/shivammathur/php5-darwin/actions/runs/40190439150 > "$RUNNER_TEMP/evidence/darwin-run.json"
    jq -e '.head_sha == "ade80158e8d31bd1fef5900f5762bf167c6b6ed2" and .run_attempt == 1' "$RUNNER_TEMP/evidence/darwin-run.json"
    gh api 'repos/shivammathur/php5-darwin/actions/runs/40190439150/artifacts?per_page=100' > "$RUNNER_TEMP/evidence/darwin-artifacts.json"
    count=$(jq '[.artifacts[] | select(.name | test("^php5[345]-caches-(arm64|x86_64)$")) | select(.expired == false)] | length' "$RUNNER_TEMP/evidence/darwin-artifacts.json")
    if [[ "$count" = 6 ]]; then exit 0; fi
    if jq -e '.status == "completed"' "$RUNNER_TEMP/evidence/darwin-run.json" >/dev/null; then
      echo "Darwin run ended with only $count of six candidate artifacts" >&2
      exit 1
    fi
    echo "Waiting for candidate artifacts: $count/6"
    sleep 60
  done
  echo 'Timed out waiting for Darwin candidates' >&2
  exit 1
fi
minor=${PHP_MINOR:?}
if ! command -v zstd >/dev/null; then
  if [[ "$RUNNER_OS" = macOS ]]; then brew install zstd; else sudo apt-get install -y zstd; fi
fi
arch=$(uname -m)
[[ "$arch" != aarch64 ]] || arch=arm64
[[ "$arch" = "$EXPECTED_ARCHITECTURE" ]]
if [[ "$mode" = ubuntu ]]; then
  suffix=''; [[ "$arch" != arm64 ]] || suffix=-arm64
  name="php-$minor-build$suffix.tar.zst"
  jq -e --arg name "$name" '.[$name]' ubuntu-assets.json > "$RUNNER_TEMP/evidence/runtime-asset.json"
  url=$(jq -r .browser_download_url "$RUNNER_TEMP/evidence/runtime-asset.json")
  expected=$(jq -r '.digest | sub("^sha256:"; "")' "$RUNNER_TEMP/evidence/runtime-asset.json")
  curl -fLS --retry 3 "$url?setup-php-test=$GITHUB_RUN_ID" -o "$RUNNER_TEMP/runtime.tar.zst"
  printf '%s  %s\n' "$expected" "$RUNNER_TEMP/runtime.tar.zst" | shasum -a 256 -c -
  zstd -t "$RUNNER_TEMP/runtime.tar.zst"
  tar -I zstd -xf "$RUNNER_TEMP/runtime.tar.zst" -C "$RUNNER_TEMP/reference"
  shasum -a 256 "$RUNNER_TEMP/reference/$minor/bin/php" | awk '{print $1}' > "$RUNNER_TEMP/evidence/expected-php.sha256"
elif [[ "$mode" = darwin ]]; then
  name="php${minor/./}-caches-$arch"
  jq -e --arg name "$name" '[.artifacts[] | select(.name == $name and .expired == false)] | if length == 1 then .[0] else error("Missing/duplicate candidate") end' "$RUNNER_TEMP/candidate-metadata/darwin-artifacts.json" > "$RUNNER_TEMP/evidence/candidate-artifact.json"
  id=$(jq -r .id "$RUNNER_TEMP/evidence/candidate-artifact.json")
  expected=$(jq -r '.digest | sub("^sha256:"; "")' "$RUNNER_TEMP/evidence/candidate-artifact.json")
  curl -fLS --retry 3 -H "Authorization: Bearer $GH_TOKEN" \
    "https://api.github.com/repos/shivammathur/php5-darwin/actions/artifacts/$id/zip" -o "$RUNNER_TEMP/candidate.zip"
  printf '%s  %s\n' "$expected" "$RUNNER_TEMP/candidate.zip" | shasum -a 256 -c -
  unzip -t "$RUNNER_TEMP/candidate.zip" > "$RUNNER_TEMP/evidence/zip-integrity.txt"
  mkdir -p "$RUNNER_TEMP/candidate" "$RUNNER_TEMP/candidate-cache"
  unzip -q "$RUNNER_TEMP/candidate.zip" -d "$RUNNER_TEMP/candidate"
  manifest=$(find "$RUNNER_TEMP/candidate" -name public-sources.json)
  [[ -f "$manifest" ]]
  jq '{repository, sources: (.sources | with_entries(.value |= {version,branch,commit,sha256}))}' "$manifest" > "$RUNNER_TEMP/evidence/candidate-sources.json"
  diff -u <(jq -S . expected-sources.json) <(jq -S . "$RUNNER_TEMP/evidence/candidate-sources.json")
  bootstrap=$(find "$RUNNER_TEMP/candidate" -name source-bootstrap.json)
  [[ -f "$bootstrap" ]]
  jq -e --arg sha "$(jq -r --arg minor "$minor" '.sources[$minor].sha256' expected-sources.json)" '.original_sha256 == $sha and .original_files_unchanged == true and (.generated_parsers | length) == 4' "$bootstrap"
  cp "$bootstrap" "$RUNNER_TEMP/evidence/source-bootstrap.json"
  find "$RUNNER_TEMP/candidate" -name '*.tar.zst' -exec cp {} "$RUNNER_TEMP/candidate-cache/" \;
  test "$(find "$RUNNER_TEMP/candidate-cache" -name '*.tar.zst' | wc -l | tr -d ' ')" = 2
  for archive in "$RUNNER_TEMP/candidate-cache"/*.tar.zst; do
    zstd -t "$archive"
    zstd -dc "$archive" | tar --nopreserveHFSCompression -xf - -C "$RUNNER_TEMP/reference"
  done
  shasum -a 256 "$RUNNER_TEMP/candidate-cache"/*.tar.zst > "$RUNNER_TEMP/evidence/candidate-SHA256SUMS"
  shasum -a 256 "$RUNNER_TEMP/reference/opt/local/bin/php${minor/./}" | awk '{print $1}' > "$RUNNER_TEMP/evidence/expected-php.sha256"
  echo "PHP5_CACHE_DIR=$RUNNER_TEMP/candidate-cache" >> "$GITHUB_ENV"
else
  echo "Unexpected mode: $mode" >&2
  exit 1
fi
