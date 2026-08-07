#!/usr/bin/env bash

set -euo pipefail

suite="$1"
php_binary="$2"
benchmark_dir="$3"

case "$suite" in
  phpstan)
    command=(
      "$php_binary" -n "$benchmark_dir/phpstan.phar" analyse
      "$benchmark_dir/PHP-Parser/lib"
      --level=max
      --no-progress
      --debug
      --memory-limit=1G
      --error-format=raw
    )
    ;;
  pgo-script)
    command=("$php_binary" -n "$benchmark_dir/pgo_script.php")
    ;;
  pgo-script-opcache)
    command=("$php_binary" -n -d opcache.enable_cli=1 "$benchmark_dir/pgo_script.php")
    ;;
  zend-bench)
    command=("$php_binary" -n "$benchmark_dir/bench.php" --repeat 3)
    ;;
  untrained-extensions)
    command=("$php_binary" -n "$benchmark_dir/untrained_extensions.php")
    ;;
  *)
    echo "Unknown benchmark suite: $suite" >&2
    exit 2
    ;;
esac

exec "${command[@]}"
