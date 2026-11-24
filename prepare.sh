#!/usr/bin/env bash
set -euo pipefail
variant=$1
session_ref=877758e9bfb1afb486e8c27948b376bfa91cb94c
old_opcache_ref=fd65a1b4c692bb6b57289de93d34e52c8657ccb0
fixed_opcache_ref=61365c15e08eaa654a4c575256f05192bf62ae77
session_blob=1d27af995a406cc2e8be94e94a7cb28bd2ba274a
case "$variant" in
    session-only)
        ref=$session_ref
        opcache_blob=40be83d1ec62bf1d850a79728c51bb01053b8fe4 ;;
    combined-before-fix)
        ref=$old_opcache_ref
        opcache_blob=d36e1ac61de9a6984e0fe7bd40442caad2721e6e ;;
    opcache-fixed|combined-fixed)
        ref=$fixed_opcache_ref
        opcache_blob=fed78e686d0effd9bab57667ea60c09f652736a0
        if [[ $variant == opcache-fixed ]]; then
            session_blob=4528ebb70bcfd596d4a168a57c152fbe0a70cfee
        fi ;;
    *) exit 2 ;;
esac
src=$(mktemp -d)
mkdir -p evidence
curl -fsSL --retry 3 "https://codeload.github.com/php/php-src/tar.gz/$ref" | tar -xz --strip-components=1 -C "$src"
printf 'Source: %s\n' "$ref" > evidence/sources.txt
if [[ $variant == combined-* ]]; then
    curl -fsSL --retry 3 "https://github.com/php/php-src/commit/$session_ref.diff" -o "$src/session.diff"
    git -C "$src" apply --stat "$src/session.diff"
    git -C "$src" apply "$src/session.diff"
    rm "$src/session.diff"
    printf 'Applied session commit: %s\n' "$session_ref" >> evidence/sources.txt
fi
test "$(git hash-object "$src/ext/session/mod_files.c")" = "$session_blob"
test "$(git hash-object "$src/ext/opcache/zend_file_cache.c")" = "$opcache_blob"
printf 'Session blob: %s\nOPcache blob: %s\n' "$session_blob" "$opcache_blob" >> evidence/sources.txt
cat evidence/sources.txt
tar -czf php-src.tar.gz -C "$src" .
