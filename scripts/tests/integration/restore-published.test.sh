#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-restore-test.XXXXXX") || \
  php_darwin_die 'could not create published-cache restore fixtures'
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
fixtures="$work_dir/fixtures"
builds="$work_dir/builds"
fake_bin="$work_dir/bin"
manifest="$fixtures/php-8.5-manifest.json"
assets_jsonl="$work_dir/assets.jsonl"
source_commit=0123456789abcdef0123456789abcdef01234567
extension_source_commit=89abcdef0123456789abcdef0123456789abcdef

mkdir -p "$fixtures" "$builds" "$fake_bin" || php_darwin_die 'could not create restore fixture directories'
: > "$assets_jsonl" || php_darwin_die 'could not initialize restore asset fixtures'
while read -r build ts; do
  asset=$(php_darwin_asset 8.5 "$build" "$ts" arm64) || exit 1
  archive_root="$work_dir/$build-$ts"
  internal_metadata=$(php_darwin_metadata_path "$asset") || exit 1
  mkdir -p "$archive_root/${internal_metadata%/*}" || php_darwin_die 'could not create restore metadata fixture path'
  jq -n --arg archive "$asset" --arg build "$build" --arg ts "$ts" \
    '{schema:1,archive:$archive,build:$build,thread_safety:$ts,architecture:"arm64",php_version:"8.5"}' \
    > "$archive_root/$internal_metadata" || php_darwin_die 'could not create restore metadata fixture'
  archive="$fixtures/$asset"
  tar -cf "$archive" -C "$archive_root" "$internal_metadata" || \
    php_darwin_die 'could not create published cache fixture'
  hash=$(php_darwin_sha256 "$archive") || php_darwin_die 'could not hash published cache fixture'
  bytes=$(wc -c < "$archive" | tr -d '[:space:]')
  download=$(php_darwin_download_asset "$asset" "$hash") || exit 1
  cp "$archive" "$fixtures/$download" || php_darwin_die 'could not stage immutable cache fixture'
  jq -cn --arg architecture arm64 --arg build "$build" --arg download "$download" \
    --arg name "$asset" --arg sha256 "$hash" --arg thread_safety "$ts" \
    --argjson bytes "$bytes" --argjson minimum_macos 14 \
    '{architecture:$architecture,build:$build,bytes:$bytes,download:$download,
      minimum_macos:$minimum_macos,name:$name,sha256:$sha256,thread_safety:$thread_safety}' \
    >> "$assets_jsonl" || php_darwin_die 'could not record published cache fixture'
done < <(php_darwin_configured_variants)

jq -s --arg extensions_commit "$extension_source_commit" --arg php_commit "$source_commit" \
  --arg hash "$(printf '%064d' 1)" '
  {schema:1,php_version:"8.5",php_semver:"8.5.1",php_src_commit:"",
   extensions_source_hash:$hash,homebrew_extensions_commit:$extensions_commit,
   homebrew_php_commit:$php_commit,source_hash:$hash,assets:.}
' "$assets_jsonl" > "$manifest" || php_darwin_die 'could not write published release manifest fixture'

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
destination=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) shift; destination=${1:-} ;;
    http*) url=$1 ;;
  esac
  shift
done
[ -n "$destination" ] && [ -n "$url" ] || exit 1
printf '%s\n' "$url" >> "${PHP_DARWIN_TEST_REQUESTS:?}"
case "$url" in https://artifacts.php-darwin.setup-php.com/*)
  case "${PHP_DARWIN_TEST_MIRROR_MODE:-hit}" in
    missing) printf '404'; exit 22 ;;
    corrupt) printf 'corrupt' > "$destination"; printf '200'; exit 0 ;;
  esac
  ;;
esac
case "$url" in
  *-manifest.json*)
    cp "${PHP_DARWIN_TEST_MANIFEST:?}" "$destination" || exit 1
    printf '200'
    ;;
  *)
    source_file="${PHP_DARWIN_TEST_FIXTURES:?}/${url##*/}"
    if [ "${PHP_DARWIN_TEST_MIRROR_MODE:-hit}" = corrupt-all-archives ]; then
      printf 'corrupt' > "$destination"
    else
      cp "$source_file" "$destination" || exit 1
    fi
    printf '200'
    ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/sleep"
chmod 0755 "$fake_bin/sleep"
chmod 0755 "$fake_bin/curl" || php_darwin_die 'could not prepare the restore curl fixture'

restore() {
  ARCH=arm64 HOMEBREW_EXTENSIONS_COMMIT="$extension_source_commit" \
    HOMEBREW_PHP_COMMIT="$source_commit" PHP_VERSION=8.5 \
    PHP_DARWIN_TEST_FIXTURES="$fixtures" PHP_DARWIN_TEST_MANIFEST="$manifest" \
    PHP_DARWIN_TEST_REQUESTS="$work_dir/requests" PHP_DARWIN_TEST_MIRROR_MODE="$1" \
    PATH="$fake_bin:$PATH" bash "$script_dir/../../cache/restore-published-architecture.sh" "$2"
}
restore hit "$builds" >/dev/null || php_darwin_die 'published cache restore validation failed'
[ "$(wc -l < "$work_dir/requests" | tr -d '[:space:]')" = 5 ] || \
  php_darwin_die 'mirror hit made unexpected requests'
if grep -q '^https://github.com/' "$work_dir/requests"; then
  php_darwin_die 'cache construction contacted GitHub despite Cloudflare hits'
fi

while read -r build ts; do
  asset=$(php_darwin_asset 8.5 "$build" "$ts" arm64) || exit 1
  [ -f "$builds/$asset" ] && [ -f "$builds/$asset.sha256" ] && \
    [ -f "$builds/${asset%.tar.zst}.json" ] || \
    php_darwin_die "published cache restore omitted $asset"
  expected_hash=$(php_darwin_checksum_from_file "$builds/$asset.sha256" "$asset") || \
    php_darwin_die "restored checksum is invalid for $asset"
  [ "$expected_hash" = "$(php_darwin_sha256 "$builds/$asset")" ] || \
    php_darwin_die "restored checksum does not match $asset"
done < <(php_darwin_configured_variants)

for mode in missing corrupt; do
  : > "$work_dir/requests"
  restore "$mode" "$work_dir/$mode" >/dev/null || php_darwin_die "$mode Cloudflare cache did not use GitHub fallback"
  [ "$(grep -c '^https://github.com/' "$work_dir/requests")" = 5 ] || \
    php_darwin_die 'fallback did not download the manifest and four archives once'
  expected=5
  [ "$mode" != missing ] || expected=15
  [ "$(grep -c '^https://artifacts.php-darwin.setup-php.com/' "$work_dir/requests")" = "$expected" ] || \
    php_darwin_die 'cache restore exceeded bounded Cloudflare retries'
done
if restore corrupt-all-archives "$work_dir/corrupt-all" > /dev/null 2>&1; then
  php_darwin_die 'cache construction accepted corrupt archives'
fi
[ -z "$(ls -A "$work_dir/corrupt-all")" ] || php_darwin_die 'failed restore retained partial archive outputs'

printf 'Published archive restore verified Cloudflare-first, GitHub fallback, checksums and partial-file cleanup\n'
