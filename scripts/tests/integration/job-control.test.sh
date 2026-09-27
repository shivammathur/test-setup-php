#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"

child_file=$(mktemp -t php-darwin-child.XXXXXX) || \
  php_darwin_die 'could not create the job-control fixture'
root_term_file=$(mktemp -t php-darwin-root-term.XXXXXX) || \
  php_darwin_die 'could not create the job-root signal fixture'
rm -f "$root_term_file" || php_darwin_die 'could not reset the job-root signal fixture'
trap 'rm -f "$child_file" "$root_term_file"' EXIT

(
  trap 'printf '\''%s\n'\'' root-terminated > "$root_term_file"; exit 143' TERM
  /bin/sh -c 'trap "" TERM; sleep 30' &
  printf '%s\n' "$!" > "$child_file"
  wait
) 2>/dev/null &
worker_pid=$!

attempt=0
while [ ! -s "$child_file" ] && [ "$attempt" -lt 50 ]; do
  sleep 0.02
  attempt=$((attempt + 1))
done
[ -s "$child_file" ] || php_darwin_die 'job-control fixture did not start'
child_pid=$(cat "$child_file") || php_darwin_die 'could not read the fixture child process'

start=$(date +%s)
php_darwin_reap_job "$worker_pid" 0
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 5 ] || php_darwin_die "job cleanup exceeded its bound: ${elapsed}s"
php_darwin_job_running "$worker_pid" && php_darwin_die 'job cleanup left its worker running'
[ "$(cat "$root_term_file")" = root-terminated ] || \
  php_darwin_die 'job cleanup did not send TERM to its worker root'

attempt=0
while php_darwin_job_running "$child_pid" && [ "$attempt" -lt 50 ]; do
  sleep 0.02
  attempt=$((attempt + 1))
done
php_darwin_job_running "$child_pid" && php_darwin_die 'job cleanup left a child process running'

printf 'Bounded process-tree cleanup validation passed (%ss)\n' "$elapsed"
