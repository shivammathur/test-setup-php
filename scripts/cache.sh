#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence
ext_dir=$(php-config --extension-dir)
if [ "$1" = seed ]; then
  php -r 'if (phpversion("redis") !== "6.1.0") { exit(1); }'
  cp "$ext_dir/redis.so" "$RUNNER_TEMP/redis-original.so"
  if [ "$CACHE_CASE" = corrupt ]; then
    printf 'invalid shared library' | sudo tee "$ext_dir/redis-6.2.0" >/dev/null
  else
    sudo cp "$ext_dir/redis.so" "$ext_dir/redis-6.2.0"
  fi
  sudo rm -f /tmp/php8.3_extensions
  printf 'redis\n' > /tmp/php8.3_extensions
else
  php -r '$r = new Redis(); if (phpversion("redis") !== "6.2.0") { exit(1); } echo json_encode(["php" => PHP_VERSION, "redis" => phpversion("redis"), "class" => get_class($r)], JSON_PRETTY_PRINT), PHP_EOL;' | tee "evidence/redis-$1.json"
  cmp "$ext_dir/redis.so" "$ext_dir/redis-6.2.0"
  if cmp -s "$ext_dir/redis.so" "$RUNNER_TEMP/redis-original.so"; then
    echo 'Recovery kept the wrong Redis version' >&2
    exit 1
  fi
  php --ri redis > "evidence/redis-$1.txt"
fi
