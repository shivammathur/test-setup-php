#!/usr/bin/env bash
brew list --versions > "$RUNNER_TEMP/brew-before" || exit 1
brew trust --json=v1 | jq -S . > "$RUNNER_TEMP/trust-before" || exit 1
php -n -r 'echo PHP_VERSION;' > "$RUNNER_TEMP/php-before" || true
[ ! -e /tmp/update_dependencies ] || exit 1
ruby -rsocket - "$RUNNER_TEMP" > "$RUNNER_TEMP/outage.log" 2>&1 <<'RUBY' &
directory = ARGV.fetch(0)
server = TCPServer.new('127.0.0.1', 0)
File.write("#{directory}/cache-server-port", server.addr[1].to_s)
count = 0
loop do
  client = server.accept
  while (line = client.gets) && line != "\r\n"; end
  count += 1
  File.write("#{directory}/cache-request-count", count.to_s)
  client.write("HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
  client.close
end
RUBY
for _ in {1..50}; do
  [ ! -s "$RUNNER_TEMP/cache-server-port" ] || break
  sleep 0.1
done
[ -s "$RUNNER_TEMP/cache-server-port" ] || exit 1
printf 'PHP_DARWIN_RELEASE_URL=http://127.0.0.1:%s/archive\n' \
  "$(cat "$RUNNER_TEMP/cache-server-port")" >> "$GITHUB_ENV"
