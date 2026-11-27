#!/usr/bin/env bash
set -e -o pipefail
root=$(cd "$1" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
sed '/^run=\$1/,$d' "$root/src/scripts/cache.sh" > "$scratch/functions.sh"
source "$scratch/functions.sh"
fail() { echo "$*" >&2; exit 1; }

(
  RUNNER_TEMP=$scratch RUNNER_TOOL_CACHE=$scratch/tools GITHUB_OUTPUT=$scratch/outputs
  version=8.7
  os=Darwin
  sw_vers() { echo 26; }
  uname() { echo "${probe_arch:-arm64}"; }
  sudo() { echo "$*" >> "$scratch/sudo"; }
  curl() {
    case "$header_case" in
      timeout) return 28;;
      bad) printf 'invalid\n' > "$header"; printf 200;;
      missing) case "${!#}" in */master/*) printf '#define PHP_API_VERSION 20261113\n' > "$header";; *) printf 404;; esac;;
    esac
  }
  for header_case in timeout bad; do
    if data; then fail 'invalid PHP API accepted'; fi
    test ! -e "$scratch/sudo" && test ! -e "$GITHUB_OUTPUT" || fail 'published metadata or used sudo on invalid API'
  done
  header_case=missing
  data
  grep -Fx "dir=/opt/homebrew/lib/php/pecl/20261113" "$GITHUB_OUTPUT" >/dev/null || grep -Fx "dir=/usr/local/lib/php/pecl/20261113" "$GITHUB_OUTPUT" >/dev/null
  cache_dir=$(cat "$RUNNER_TEMP/dir")
  grep -Fx "chown -R $USER:$(id -g -n) $cache_dir" "$scratch/sudo"
  version=8.2; os=Darwin; data
  first=$(cat "$scratch/deps-dir")
  version=8.3; os=Darwin; data
  second=$(cat "$scratch/deps-dir")
  probe_arch=x86_64; os=Darwin; data
  third=$(cat "$scratch/deps-dir")
  test "$first" = "$RUNNER_TOOL_CACHE/deps/arm64-20220829"
  test "$second" = "$RUNNER_TOOL_CACHE/deps/arm64-20230831"
  test "$third" = "$RUNNER_TOOL_CACHE/deps/x86_64-20230831"
)
echo "PASS: invalid ABI, ownership boundary, ABI and architecture scoping"

(
  if [[ $(uname -s) == Darwin && -d /opt/homebrew/opt/gnu-sed/libexec/gnubin ]]; then PATH="/opt/homebrew/opt/gnu-sed/libexec/gnubin:$PATH"; fi
  source "$root/src/scripts/linux.sh"
  script_dir=$root/src/scripts
  cat > "$scratch/Packages" <<'PKG'
Package: php8.2-xmlrpc
Depends: php8.2-false, libunrelated1
Filename: pool/incorrect.deb

Package: php8.2-xml
Depends: php8.2-common (>= 8.2), libxml2 (>= 2.0)
Filename: pool/xml.deb

Package: php8.2-xml-dbgsym
Depends: php8.2-xml
Filename: pool/debug.deb
PKG
  awk() {
    local args=() arg
    for arg in "$@"; do
      if [[ $arg = /tmp/Packages ]]; then arg=$scratch/Packages; fi
      args+=("$arg")
    done
    command awk "${args[@]}"
  }
  test "$(get_dependencies php8.2-xml php8.2-)" = php8.2-common
  test "$(get_dependencies php8.2-xml lib)" = libxml2
  test "$(get_package_field php8.2-xml Filename)" = pool/xml.deb
  echo "PASS: exact Depends and Filename for prefixed package names"

  deps_cache_directory=$scratch/deps; extdir=$scratch/ext; version=8.2; tick='ok'; fail_fast=true
  mkdir -p "$deps_cache_directory" "$extdir"
  download_ppa_package() { [[ $1 != php8.2-a ]] || return 1; touch "$2"; }
  sudo() {
    case "$1" in
      dpkg-deb) echo binary > "$extdir/$dependency_extension.so"; [[ ${scenario:-} != extract ]] || return 2;;
      rm) command rm "${@:2}";;
      chown) :;;
      cp) if [[ ${scenario:-} == restore ]]; then echo partial > "$extdir/$dependency_extension.so"; return 1; fi
          [[ ${scenario:-} != copy ]] || { echo partial > "${!#}"; return 1; }; command cp "${@:2}";;
      *) fail "unexpected sudo: $*";;
    esac
  }
  if setup_extensions "$extdir" 'a b' > "$scratch/setup-log"; then fail 'worker error hidden'; fi
  if grep -q 'Added' "$scratch/setup-log"; then fail 'misleading success log'; fi
  test -s "$deps_cache_directory/b.so"
  for scenario in extract copy; do
    if setup_extensions_helper "$scenario" "$extdir"; then fail "ignored failure in $scenario"; fi
    test ! -e "$deps_cache_directory/$scenario.so" && test ! -e "$extdir/$scenario.so"
    failed_module=$scenario
    scenario=retry
    setup_extensions_helper "$failed_module" "$extdir"
    cmp "$extdir/$failed_module.so" "$deps_cache_directory/$failed_module.so"
  done
  test -z "$(find "$deps_cache_directory" -name '.download.*' -print)"
  rm "$extdir/b.so"
  scenario=restore
  if setup_extensions_helper b "$extdir"; then fail 'partial warm restore accepted'; fi
  test ! -e "$extdir/b.so" && test -s "$deps_cache_directory/b.so"
  scenario=retry
  setup_extensions_helper b "$extdir"
  cmp "$extdir/b.so" "$deps_cache_directory/b.so"
  echo "PASS: parallel failure, successful sibling, extraction and cold/warm partial-copy recovery"
)
(
  brew() { :; }
  source "$root/src/scripts/darwin.sh"
  brew_cellar=$scratch/cellar; brew_prefix=$scratch/brew; deps_cache_directory=$scratch/mac-deps; tick=OK
  mkdir -p "$brew_cellar/good" "$brew_cellar/bad" "$brew_prefix/opt"
  echo good > "$brew_cellar/good/contents"; echo bad > "$brew_cellar/bad/contents"
  sudo() { "$@"; }
  gtar() {
    if [[ $break_tar == yes && ${!#} == bad ]]; then echo partial > "$4"; return 2; fi
    if type -P gtar >/dev/null; then command gtar "$@"; else command tar "$@"; fi
  }
  break_tar=yes
  if setup_libraries fixture good bad; then fail 'archive failure hidden'; fi
  test ! -e "$deps_cache_directory/fixture/list"
  test ! -e "$deps_cache_directory/fixture/bad.tar.zst"
  test -z "$(find "$deps_cache_directory/fixture" \( -name 'list.*' -o -name '*.tar.zst.*' \) -print)"
  break_tar=no
  setup_libraries fixture good bad
  diff -u <(printf '%s\n' bad good) <(sort "$deps_cache_directory/fixture/list")
  for lib in good bad; do mv "$brew_cellar/$lib" "$scratch/before-$lib"; done
  setup_libraries fixture good bad
  for lib in good bad; do cmp "$scratch/before-$lib/contents" "$brew_cellar/$lib/contents"; done
  echo "PASS: failed archive, clean retry, complete manifest, byte-for-byte restore"
  command() {
    if [[ $1 == -v && $2 == gtar ]]; then return 1; fi
    builtin command "$@"
  }
  setup_libraries portable good
  zstd -dc "$deps_cache_directory/portable/good.tar.zst" | tar -tf - | grep -q 'good/contents'
  echo "PASS: tar-and-zstd fallback writes a readable archive"
  for attempt in 1 2; do
    mv "$brew_cellar/good" "$scratch/portable-before-$attempt"
    setup_libraries portable good
    cmp "$scratch/portable-before-$attempt/contents" "$brew_cellar/good/contents"
    test ! -e "$deps_cache_directory/portable/good.tar"
    echo "PASS: portable restore $attempt on a persistent dependency directory"
  done
)

(
  brew() { if [[ $1 == install || $1 == fetch ]]; then return 1; fi; }
  source "$root/src/scripts/darwin.sh"
  deps_cache_directory=$scratch/extension-files
  ext_config_directory=$scratch/config
  cache_directory=$ext_config_directory
  extdir=$scratch/install
  mkdir -p "$deps_cache_directory" "$extdir"
  sudo() { "$@"; }
  if setup_extensions memcached "$extdir" homebrew/extensions/igbinary@8.4; then fail 'brew and bottle failure hidden'; fi
  test ! -e "$ext_config_directory/memcached/igbinary"
  test -z "$(ls -A "$deps_cache_directory")"
  brew_prefix=$scratch/prefix
  mkdir -p "$brew_prefix/opt/igbinary@8.4"
  brew() { :; }
  if setup_extensions memcached "$extdir" homebrew/extensions/igbinary@8.4; then fail 'empty keg accepted'; fi
  test -z "$(ls -A "$deps_cache_directory")"
  echo valid > "$brew_prefix/opt/igbinary@8.4/igbinary.so"
  tick=OK
  setup_extensions memcached "$extdir" homebrew/extensions/igbinary@8.4
  cmp "$extdir/igbinary.so" "$deps_cache_directory/igbinary.so"
  test "$(cat "$ext_config_directory/memcached/igbinary")" = igbinary
  echo "PASS: missing formula and missing binary fail cleanly, successful retry restores real bytes"
)
