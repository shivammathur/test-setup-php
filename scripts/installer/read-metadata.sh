#!/usr/bin/env bash

archive=${1:?}
member=${2:?}
output=${3:?}

[ -f "$archive" ] || {
  printf 'Archive not found: %s\n' "$archive" >&2
  exit 1
}
[[ "$member" =~ ^var/php-darwin/php_[0-9]+\.[0-9]+-(nts|zts)-(debug|release)\+darwin_(arm64|x86_64)\.json$ ]] || {
  printf 'Unsafe metadata member: %s\n' "$member" >&2
  exit 1
}
# Metadata is the first member. Stop as soon as tar has read it instead of
# decompressing every keg. The caller authenticates the entire archive first.
# zstd -f also passes through plain tar input used by validation fixtures.
case "$(tar --version)" in
  *bsdtar*) metadata_options=(-q) ;;
  *) metadata_options=(--occurrence=1) ;;
esac
zstd -qdcf "$archive" 2> "$output.zstd.log" | \
  tar --ignore-zeros -xOf - "${metadata_options[@]}" "$member" > "$output"
metadata_status=("${PIPESTATUS[@]}")
# Some zstd versions handle EPIPE themselves and return their write-error code
# instead of SIGPIPE. Accept only that diagnostic after tar read the full member.
if [ "${metadata_status[0]}" -eq 70 ] && \
  grep -Eq '^zstd: error 70 : Write error : .*Broken pipe *$' "$output.zstd.log"; then
  metadata_status[0]=141
fi
if [ "${metadata_status[1]}" -ne 0 ] || \
  { [ "${metadata_status[0]}" -ne 0 ] && [ "${metadata_status[0]}" -ne 141 ]; }; then
  cat "$output.zstd.log" >&2
  rm -f "$output.zstd.log" "$output"
  exit 1
fi
rm -f "$output.zstd.log"
if [ ! -s "$output" ]; then
  rm -f "$output"
  exit 1
fi
