const assert = require('node:assert/strict');
const {spawnSync} = require('node:child_process');
const path = require('node:path');
const {test} = require('node:test');

function run(source) {
  return spawnSync('/bin/bash', ['-c', '. "$1"; ' + source, 'test', path.join(__dirname, '../../lib/lib.sh')], {
    encoding: 'utf8'
  });
}

test('tap lookup uses the fast Homebrew root command and retains custom-layout fallback', () => {
  const result = run(`
    directory=$(mktemp -d)
    mkdir -p "$directory/Library/Homebrew"
    brew() {
      if [ "$#" -eq 1 ]; then printf '%s\\n' "$directory"; else printf 'native-tap-path\\n'; fi
    }
    result=$(php_darwin_tap_repository_path example/homebrew-tools)
    [ "$result" = "$directory/Library/Taps/example/homebrew-tools" ] || exit 1
    rmdir "$directory/Library/Homebrew"
    [ "$(php_darwin_tap_repository_path example/tools)" = native-tap-path ] || exit 2
    [ "$(php_darwin_tap_repository_path Example/Tools)" = native-tap-path ] || exit 3
    rm -rf "$directory"
  `);
  assert.equal(result.status, 0, result.stderr);
});

test('runtime selection probes installed portable Ruby and falls back without downloading', () => {
  const result = run(`
    directory=$(mktemp -d)
    brew() { [ "$*" = --repository ] || return 99; printf '%s\\n' "$directory"; }
    candidate="$directory/Library/Homebrew/vendor/portable-ruby/current/bin/ruby"
    mkdir -p "$(dirname "$candidate")"
    printf '#!/bin/sh\\nexit 0\\n' > "$candidate"
    chmod +x "$candidate"
    php_darwin_select_ruby
    [ "$PHP_DARWIN_RUBY" = "$candidate" ] || exit 1
    printf '#!/bin/sh\\nexit 1\\n' > "$candidate"
    php_darwin_select_ruby
    [ "$PHP_DARWIN_RUBY" = /usr/bin/ruby ] || exit 2
    rm "$candidate"
    php_darwin_select_ruby
    [ "$PHP_DARWIN_RUBY" = /usr/bin/ruby ] || exit 3
    rm -rf "$directory"
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, '');
});
