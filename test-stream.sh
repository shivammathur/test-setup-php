#!/usr/bin/env bash
set -euo pipefail

mkdir -p reports
fixture_dir=$(mktemp -d)
server_pid=
trap 'if [ -n "$server_pid" ]; then kill "$server_pid"; fi; rm -rf "$fixture_dir"' EXIT
mkdir "$fixture_dir/input" "$fixture_dir/output"
dd if=/dev/urandom of="$fixture_dir/input/payload" bs=1024 count=256 status=none
tar -I zstd -cf "$fixture_dir/fixture.tar.zst" -C "$fixture_dir/input" payload
node server.cjs "$fixture_dir/fixture.tar.zst" "$PWD/reports/requests.log" &
server_pid=$!
for _ in {1..100}; do
  [ -s reports/requests.log.port ] && break
  sleep 0.1
done
base="http://127.0.0.1:$(cat reports/requests.log.port)"

# Load only the functions; redirect extraction into the disposable fixture directory.
# shellcheck disable=SC1090
source <(sed '/^export DEBIAN_FRONTEND/,$d' cache/scripts/install.sh)
sudo() {
  local args=("$@")
  if [ "$1" = tar ]; then
    [ "${FAIL_TAR:-false}" = false ] || return 1
    args[${#args[@]}-1]="$fixture_dir/output"
  fi
  command "${args[@]}"
}

download_and_extract "$fixture_dir/download.tar.zst" \
  "$base/http-error" "$base/truncated" "$base/late-error" "$base/corrupt" "$base/ok" >reports/fallback.log 2>&1
cmp "$fixture_dir/fixture.tar.zst" "$fixture_dir/download.tar.zst"
cmp "$fixture_dir/input/payload" "$fixture_dir/output/payload"
printf '/http-error\n/truncated\n/late-error\n/corrupt\n/ok\n' > "$fixture_dir/expected-requests"
cmp "$fixture_dir/expected-requests" reports/requests.log

if download_and_extract "$fixture_dir/download.tar.zst" "$base/http-error" "$base/truncated" >reports/all-failed.log 2>&1; then
  echo 'All failed mirrors incorrectly reported success'
  exit 1
fi
if FAIL_TAR=true download_and_extract "$fixture_dir/download.tar.zst" "$base/ok" >reports/extraction-failed.log 2>&1; then
  echo 'Failed extraction incorrectly reported success'
  exit 1
fi
echo 'HTTP errors, truncated transfers, late transfer failures, checksum errors and extraction failures handled correctly.' | tee reports/result.txt
