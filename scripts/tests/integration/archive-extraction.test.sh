#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

command -v zstd >/dev/null 2>&1 || php_darwin_die 'zstd is required for extraction validation'
fixture_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-validation.XXXXXX")
trap 'chmod u+w "$fixture_dir/prefix/lib/php" 2>/dev/null || true; rm -rf "$fixture_dir"' EXIT
fixture_source="$fixture_dir/source"
fixture_prefix="$fixture_dir/prefix"
fixture_archive="$fixture_dir/cache.tar.zst"
fixture_paths="$fixture_dir/archive-paths.txt"
fixture_excludes="$fixture_dir/excludes.txt"
fixture_kegs="$fixture_dir/kegs.txt"
fixture_managed_paths="$fixture_dir/managed-paths.txt"
fixture_package_kegs="$fixture_dir/package-kegs.txt"
fixture_metadata="$fixture_dir/metadata.json"
fixture_contents="$fixture_dir/archive-contents.txt"
fixture_links="$fixture_dir/links.tsv"
fixture_links_log="$fixture_dir/links.log"
fixture_outside="$fixture_dir/outside"
fixture_symlink_prefix="$fixture_dir/symlink-prefix"
fixture_symlink_log="$fixture_dir/symlink-rack.log"
fixture_unsafe_managed_paths="$fixture_dir/unsafe-managed-paths.txt"
fixture_unsafe_root_log="$fixture_dir/unsafe-root.log"
fixture_bad_snapshot_roots="$fixture_dir/bad-snapshot-paths.txt"
fixture_snapshot_manifest="$fixture_dir/filesystem-manifest.tsv"
fixture_truncated_archive="$fixture_dir/truncated.tar"
fixture_plain_archive="$fixture_dir/metadata.tar"
mkdir -p "$fixture_source/Cellar/php/1/bin" "$fixture_source/Cellar/php/1/lib" \
  "$fixture_source/Cellar/dependency/1/bin" \
  "$fixture_source/lib/php/20200930" \
  "$fixture_source/etc" "$fixture_source/opt" \
  "$fixture_source/share/pear" "$fixture_source/var/homebrew/linked" "$fixture_source/var/php-darwin" \
  "$fixture_source/etc/existing-link" "$fixture_prefix/Cellar/dependency/1/bin" \
  "$fixture_prefix/Cellar/hello/1/bin" "$fixture_prefix/etc" \
  "$fixture_prefix/Frameworks" "$fixture_prefix/bin" "$fixture_prefix/include" \
  "$fixture_prefix/lib/php" \
  "$fixture_prefix/opt" "$fixture_prefix/sbin" "$fixture_prefix/share/pear" "$fixture_prefix/var" \
  "$fixture_outside" "$fixture_symlink_prefix/Cellar" || \
  php_darwin_die 'could not create extraction fixtures'
printf '#!/usr/bin/env bash\nprintf fixture-php\\n\n' > "$fixture_source/Cellar/php/1/bin/php"
chmod 0755 "$fixture_source/Cellar/php/1/bin/php"
printf 'archive-dependency\n' > "$fixture_source/Cellar/dependency/1/bin/dependency"
printf 'archive-oniguruma\n' > "$fixture_source/Cellar/php/1/lib/libonig.5.dylib"
printf 'cached-extension\n' > "$fixture_source/lib/php/20200930/cache.so"
printf 'existing-dependency\n' > "$fixture_prefix/Cellar/dependency/1/bin/dependency"
printf 'existing-oniguruma\n' > "$fixture_prefix/lib/libonig.5.dylib"
printf 'archive-value\n' > "$fixture_source/etc/existing[1].conf"
printf 'retained-value\n' > "$fixture_source/etc/existing1.conf"
printf 'must-not-escape\n' > "$fixture_source/etc/existing-link/new.conf"
ln -s ../Cellar/php/1 "$fixture_source/opt/php"
ln -s ../../../Cellar/php/1 "$fixture_source/var/homebrew/linked/php"
printf '{"fixture":true}\n' > \
  "$fixture_source/var/php-darwin/php_8.5-nts-release+darwin_arm64.json"
printf 'cached-pear\n' > "$fixture_source/share/pear/new.php"
printf 'existing-pear\n' > "$fixture_prefix/share/pear/existing.php"
printf 'user-value\n' > "$fixture_prefix/etc/existing[1].conf"
chmod 0444 "$fixture_prefix/etc/existing[1].conf"
chmod 0555 "$fixture_prefix/lib/php"
ln -s "$fixture_outside" "$fixture_prefix/etc/existing-link"
printf '#!/usr/bin/env bash\nprintf hello\\n\n' > "$fixture_prefix/Cellar/hello/1/bin/hello"
chmod 0755 "$fixture_prefix/Cellar/hello/1/bin/hello"
printf '%s\n' var/php-darwin/php_8.5-nts-release+darwin_arm64.json \
  Cellar/dependency/1/bin/dependency Cellar/php/1/bin/php \
  Cellar/php/1/lib/libonig.5.dylib \
  'etc/existing[1].conf' etc/existing1.conf etc/existing-link/new.conf lib/php/20200930/cache.so \
  opt/php share/pear/new.php \
  var/homebrew/linked/php > "$fixture_paths"
awk '$0 !~ /^Cellar\//' "$fixture_paths" > "$fixture_managed_paths" || \
  php_darwin_die 'could not create managed path fixtures'
printf '%s\n' lib/libonig.5.dylib >> "$fixture_managed_paths" || \
  php_darwin_die 'could not add the suffix-collision fixture'
printf '%s\n' Cellar/dependency/1 Cellar/php/1 > "$fixture_package_kegs" || \
  php_darwin_die 'could not create package keg fixtures'
tar --no-recursion -cf - -C "$fixture_source" -T "$fixture_paths" | zstd -3 -q -o "$fixture_archive"
fixture_status=("${PIPESTATUS[@]}")
[ "${fixture_status[0]}" -eq 0 ] && [ "${fixture_status[1]}" -eq 0 ] || \
  php_darwin_die 'could not create the extraction fixture archive'
bash "$script_dir/../../installer/existing-paths.sh" "$fixture_prefix" "$fixture_excludes" \
  "$script_dir/../../../conf/archive-paths" "$fixture_kegs" "$fixture_managed_paths" \
  "$fixture_package_kegs" || \
  php_darwin_die 'could not create fixture exclusions'
grep -Fxq 'Cellar/dependency/1' "$fixture_excludes" || \
  php_darwin_die 'existing package keg was not excluded as one subtree'
grep -Fxq 'Cellar/dependency/1' "$fixture_kegs" || php_darwin_die 'existing package keg inventory is incomplete'
! grep -Fq 'Cellar/hello/1' "$fixture_excludes" || php_darwin_die 'unrelated keg was unnecessarily scanned'
bash "$script_dir/../../installer/extract.sh" "$fixture_archive" "$fixture_prefix" "$fixture_excludes" \
  "$fixture_managed_paths" "$fixture_package_kegs" || \
  php_darwin_die 'direct compressed extraction fixture failed'
bash "$script_dir/../../build/list-archive.sh" "$fixture_archive" "$fixture_contents" || \
  php_darwin_die 'direct compressed archive listing fixture failed'
bash "$script_dir/../../installer/read-metadata.sh" "$fixture_archive" \
  var/php-darwin/php_8.5-nts-release+darwin_arm64.json "$fixture_metadata" || \
  php_darwin_die 'embedded metadata read fixture failed'
[ "$(cat "$fixture_metadata")" = '{"fixture":true}' ] || \
  php_darwin_die 'embedded metadata read fixture returned the wrong content'
for write_error in 'Broken pipe' 'No space left on device'; do
  (
    # Exported for the metadata reader subprocess.
    # shellcheck disable=SC2329
    zstd() {
      command zstd "$@" || return $?
      printf 'zstd: error 70 : Write error : cannot write block : %s \n' "$write_error" >&2
      return 70
    }
    export -f zstd
    export write_error
    bash "$script_dir/../../installer/read-metadata.sh" "$fixture_archive" \
      var/php-darwin/php_8.5-nts-release+darwin_arm64.json "$fixture_metadata" 2>/dev/null
  )
  metadata_status=$?
  case "$write_error" in
    'Broken pipe') [ "$metadata_status" -eq 0 ] || php_darwin_die 'zstd EPIPE was treated as corrupt metadata' ;;
    *) [ "$metadata_status" -ne 0 ] || php_darwin_die 'metadata reader ignored an unexpected zstd write error' ;;
  esac
done
tar -cf "$fixture_plain_archive" -C "$fixture_source" \
  var/php-darwin/php_8.5-nts-release+darwin_arm64.json || \
  php_darwin_die 'could not create the metadata truncation fixture'
dd if="$fixture_plain_archive" of="$fixture_truncated_archive" bs=1 count=530 2>/dev/null || \
  php_darwin_die 'could not truncate the metadata archive fixture'
if bash "$script_dir/../../installer/read-metadata.sh" "$fixture_truncated_archive" \
  var/php-darwin/php_8.5-nts-release+darwin_arm64.json "$fixture_metadata" 2>/dev/null; then
  php_darwin_die 'metadata reader accepted a truncated archive'
fi
[ ! -e "$fixture_metadata" ] || php_darwin_die 'metadata reader kept partial output from a truncated archive'
[ "$(cat "$fixture_prefix/etc/existing[1].conf")" = user-value ] || \
  php_darwin_die 'direct extraction replaced an existing file'
[ "$(cat "$fixture_prefix/etc/existing1.conf")" = retained-value ] || \
  php_darwin_die 'extraction interpreted a literal exclusion path as a wildcard'
fixture_mode=$(stat -f '%Lp' "$fixture_prefix/etc/existing[1].conf" 2>/dev/null || true)
case "$fixture_mode" in 444) ;; *) fixture_mode=$(stat -c '%a' "$fixture_prefix/etc/existing[1].conf") || \
  php_darwin_die 'could not inspect fixture permissions' ;; esac
[ "$fixture_mode" = 444 ] || \
  php_darwin_die 'direct extraction changed existing permissions'
[ -x "$fixture_prefix/Cellar/php/1/bin/php" ] || php_darwin_die 'direct extraction lost executable permissions'
[ "$(cat "$fixture_prefix/Cellar/php/1/lib/libonig.5.dylib")" = archive-oniguruma ] || \
  php_darwin_die 'an unanchored exclusion suppressed a file inside the PHP keg'
[ "$(cat "$fixture_prefix/lib/libonig.5.dylib")" = existing-oniguruma ] || \
  php_darwin_die 'direct extraction replaced the linked dependency fixture'
[ "$(cat "$fixture_prefix/lib/php/20200930/cache.so")" = cached-extension ] || \
  php_darwin_die 'direct extraction did not recover from an unwritable Homebrew directory'
fixture_php_mode=$(stat -f '%Lp' "$fixture_prefix/lib/php" 2>/dev/null || true)
case "$fixture_php_mode" in 555) ;; *)
  fixture_php_mode=$(stat -c '%a' "$fixture_prefix/lib/php") || \
    php_darwin_die 'could not inspect restored Homebrew directory permissions'
  ;;
esac
[ "$fixture_php_mode" = 555 ] || \
  php_darwin_die 'direct extraction did not restore Homebrew directory permissions'
[ "$(readlink "$fixture_prefix/opt/php")" = ../Cellar/php/1 ] || php_darwin_die 'direct extraction lost the PHP opt link'
[ "$(readlink "$fixture_prefix/var/homebrew/linked/php")" = ../../../Cellar/php/1 ] || \
  php_darwin_die 'direct extraction omitted the Homebrew linked-keg marker'
printf '%s\t%s\n' opt/php ../Cellar/php/1 \
  var/homebrew/linked/php ../../../Cellar/php/1 > "$fixture_links" || \
  php_darwin_die 'could not create the Homebrew link fixture'
bash "$script_dir/../../installer/verify-links.sh" "$fixture_prefix" "$fixture_links" || \
  php_darwin_die 'bulk Homebrew link verification failed'
ln -sfn ../Cellar/php/invalid "$fixture_prefix/opt/php" || \
  php_darwin_die 'could not change the Homebrew link fixture'
if bash "$script_dir/../../installer/verify-links.sh" "$fixture_prefix" "$fixture_links" 2> "$fixture_links_log"; then
  php_darwin_die 'bulk Homebrew link verification accepted a wrong target'
fi
grep -Fq 'Cached Homebrew links do not match the archive manifest' "$fixture_links_log" || \
  php_darwin_die 'bulk Homebrew link verification did not explain the mismatch'
ln -sfn ../Cellar/php/1 "$fixture_prefix/opt/php" || \
  php_darwin_die 'could not restore the Homebrew link fixture'
[ -x "$fixture_prefix/Cellar/hello/1/bin/hello" ] || php_darwin_die 'direct extraction removed an existing formula'
[ "$(cat "$fixture_prefix/Cellar/dependency/1/bin/dependency")" = existing-dependency ] || \
  php_darwin_die 'direct extraction replaced an existing package keg'
[ "$(cat "$fixture_prefix/share/pear/existing.php")" = existing-pear ] || \
  php_darwin_die 'direct extraction changed existing PEAR state'
[ "$(cat "$fixture_prefix/share/pear/new.php")" = cached-pear ] || \
  php_darwin_die 'direct extraction omitted cached PEAR state'
[ ! -e "$fixture_outside/new.conf" ] || php_darwin_die 'direct extraction followed an existing symlink outside Homebrew'
ln -s "$fixture_outside" "$fixture_symlink_prefix/Cellar/dependency" || \
  php_darwin_die 'could not create the symlinked formula rack fixture'
if bash "$script_dir/../../installer/existing-paths.sh" "$fixture_symlink_prefix" "$fixture_excludes" \
  "$script_dir/../../../conf/archive-paths" "$fixture_kegs" "$fixture_managed_paths" \
  "$fixture_package_kegs" 2> "$fixture_symlink_log"; then
  php_darwin_die 'existing-path scan accepted a symlinked formula rack'
fi
grep -Fxq 'Homebrew formula rack is a symlink: Cellar/dependency' "$fixture_symlink_log" || \
  php_darwin_die 'symlinked formula rack failure was not explained'
printf '%s\n' 'C*/escape' > "$fixture_unsafe_managed_paths" || \
  php_darwin_die 'could not create the unsafe managed-root fixture'
if bash "$script_dir/../../installer/existing-paths.sh" "$fixture_prefix" "$fixture_excludes" \
  "$script_dir/../../../conf/archive-paths" "$fixture_kegs" "$fixture_unsafe_managed_paths" \
  "$fixture_package_kegs" 2> "$fixture_unsafe_root_log"; then
  php_darwin_die 'existing-path scan accepted a managed-root pattern'
fi
grep -Fxq 'Unsafe managed archive root: C*' "$fixture_unsafe_root_log" || \
  php_darwin_die 'unsafe managed-root failure was not explained'

printf 'etc unexpected\n' > "$fixture_bad_snapshot_roots" || \
  php_darwin_die 'could not create the malformed snapshot-root fixture'
if bash "$script_dir/../../build/filesystem-manifest.sh" "$fixture_prefix" "$fixture_snapshot_manifest" \
  "$fixture_bad_snapshot_roots" >/dev/null 2>&1; then
  php_darwin_die 'filesystem manifest accepted a malformed snapshot root'
fi
mkdir -p "$fixture_prefix/var/homebrew/pinned" || \
  php_darwin_die 'could not create the pinned-state fixture'
ln -s ../../Cellar/dependency/1 "$fixture_prefix/var/homebrew/pinned/dependency" || \
  php_darwin_die 'could not create the pinned-state link fixture'
bash "$script_dir/../../build/filesystem-manifest.sh" "$fixture_prefix" "$fixture_snapshot_manifest" \
  "$script_dir/../../../conf/snapshot-paths" || php_darwin_die 'filesystem manifest fixture failed'
! grep -Fq 'var/homebrew/pinned' "$fixture_snapshot_manifest" || \
  php_darwin_die 'filesystem manifest captured temporary Homebrew pins'


printf 'archive-extraction validation passed\n'
