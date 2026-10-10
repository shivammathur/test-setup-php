#!/usr/bin/env bash
set -e
repo=$1
scenario=$2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Redirect the installer's temporary state so each test is isolated.
sed "s#/tmp/composer#$work/composer#g" "$repo/src/scripts/tools/add_tools.sh" > "$work/add_tools.sh"
source "$work/add_tools.sh"
composer_bin="$work/bin"
composer_lock="$work/composer.lock"
tool_path_dir="$work/tools"
printf '2.9.0' > "$work/composer_version"
printf 'versions : * 9.9.9\n' > "$work/composer.log"
fail_fast=true
tick=ok
cross=error
sudo() { "$@"; }
enable_extensions() { :; }
add_path() { printf 'PATH %s\n' "$1"; }
add_tools_helper() { :; }
add_log() { printf '%s %s %s\n' "$@"; if [ "$1" = error ]; then exit 1; fi; }
add_tool() {
  printf 'FALLBACK %s %s %s\n' "$@"
  if [ "$scenario" = both-fail ]; then add_log error phpstan 'PHAR failed'; fi
}
composer() {
  if [ "$1" = global ]; then shift; fi
  if [ "$1" = require ]; then
    printf 'require\n' >> "$work/attempts"
    case "$scenario" in success|retry|no-show) mkdir -p "$scoped_dir/vendor"; touch "$scoped_dir/vendor/autoload.php";; *) return 1;; esac
  elif [ "$1" = show ]; then
    case " $* " in *' -a '*) return 0;; esac
    if [ "$scenario" = no-show ]; then return 1; fi
    printf 'versions : * 2.3.0\n'
  fi
}
release=phpstan
scoped_dir="$composer_bin/_tools/phpstan-$(printf %s "$release" | shasum -a 256 | cut -d ' ' -f 1)"
case "$scenario" in
  cached) mkdir -p "$scoped_dir/vendor"; touch "$scoped_dir/vendor/autoload.php";;
  retry) mkdir -p "$scoped_dir";;
esac
fallback=https://example.com/phpstan.phar
scope=scoped
[ "$scenario" != no-fallback ] || fallback=
[ "$scenario" != global-failure ] || scope=global
add_composer_tool phpstan "$release" phpstan/ "$scope" "$fallback" -V
case "$scenario" in
  cached) test ! -f "$work/attempts";;
  retry) test "$(wc -l < "$work/attempts" | tr -d ' ')" = 1;;
esac
