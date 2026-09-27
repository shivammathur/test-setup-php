#!/usr/bin/env bash
# The dynamically loaded archive function reads and writes these fixture globals.
# shellcheck disable=SC2034,SC2154
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../../lib/lib.sh"
work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-download-test.XXXXXX")
server_pid=
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'verified fixture\n' > "$work_dir/fixture"
expected_hash=$(php_darwin_sha256 "$work_dir/fixture")
version=8.3
channel=stable
release_repository=fixture/repo
asset=$(php_darwin_asset "$version" release nts arm64)
manifest_download_asset=$(php_darwin_download_asset "$asset" "$expected_hash")
archive="$work_dir/archive"
jq -n --arg hash "$expected_hash" --arg asset "$manifest_download_asset" '
  {schema:1,php_version:"8.3",php_semver:"8.3.1",php_src_commit:"",source_hash:$hash,
   extensions_source_hash:$hash,homebrew_extensions_commit:("a"*40),homebrew_php_commit:("a"*40),
   assets:[ ["arm64","x86_64"][] as $arch | ["release","debug"][] as $build | ["nts","zts"][] as $ts |
     ("php_8.3-"+$ts+"-"+$build+"+darwin_"+$arch+".tar.zst") as $name |
     {architecture:$arch,build:$build,thread_safety:$ts,name:$name,sha256:$hash,bytes:17,
      download:($name|sub(".tar.zst$";"."+$hash+".tar.zst")), minimum_macos:(if $arch=="arm64" then 14 else 15 end)}]}
' > "$work_dir/manifest"
php_darwin_validate_release_manifest "$work_dir/manifest" "$version" >/dev/null
# Exercise manifest selection and archive downloading without touching Homebrew.
sed -n '/^php_darwin_use_release_manifest() {/,/^}/p; /^php_darwin_download_release_archive() {/,/^}/p' \
  "$script_dir/../../installer/install-package.sh" > "$work_dir/download.sh"
# shellcheck source=/dev/null
. "$work_dir/download.sh"
php_darwin_use_release_manifest "$work_dir/manifest"
[ "$manifest_archive_bytes" = 17 ] || php_darwin_die 'selected the wrong archive size'
php_darwin_start_archive_hash() {
  wc -c < "$1" | tr -d ' ' >> "$work_dir/hashes"
  actual_hash=$(php_darwin_sha256 "$1")
}
php_darwin_wait_for_archive_hash() { :; }
# Backoff arithmetic is tested separately; retain real socket timeouts here.
sleep() { :; }
ruby -rsocket - "$work_dir" <<'RUBY' &
directory = ARGV.fetch(0)
server = TCPServer.new('127.0.0.1', 0)
File.write("#{directory}/port", server.addr[1].to_s)
loop do
  client = server.accept
  Thread.new(client) do |connection|
    begin
      request = connection.gets
      next unless request
      route = request.split[1]
      headers = []
      while (line = connection.gets) && line != "\r\n"; headers << line; end
      range = headers.join.match(/Range: bytes=(\d+)-/i)&.captures&.first&.to_i
      File.open("#{directory}/requests", 'a') { |f| f.puts(route) }
      mode = route.split('/')[1]
      count = File.readlines("#{directory}/requests").count { |line| line.strip == route }
      if mode == 'retry-http' && count < 3 || mode == 'always-524' || mode == 'forbidden'
        status = mode == 'forbidden' ? 403 : 524
        connection.write("HTTP/1.1 #{status} Fixture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        next
      end
      if mode == 'error-stall'
        connection.write("HTTP/1.1 503 Fixture\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\n")
        sleep 5
        next
      end
      if mode == 'trickle'
        connection.write("HTTP/1.1 200 Fixture\r\nContent-Length: 3276800\r\nConnection: close\r\n\r\n")
        200.times { connection.write('x' * 16); sleep 0.1 }
        next
      end
      sleep 20 if mode == 'stall'
      # Healthy downloads must survive the former three-second GitHub cutoff.
      sleep 4 if mode == 'moderate'
      status = {'missing'=>404,'unavailable'=>503}.fetch(mode, 200)
      if mode == 'burst'
        body = 'x' * 16384
        connection.write("HTTP/1.1 200 Fixture\r\nContent-Length: #{body.bytesize + 1}\r\nConnection: close\r\n\r\n#{body}")
        sleep 20
        next
      end
      body = File.read("#{directory}/#{route.end_with?('manifest.json') ? 'manifest' : 'fixture'}")
      body = 'invalid bytes' if mode == 'corrupt'
      length = body.bytesize
      body = body.byteslice(0, 5) if mode == 'partial'
      # Curl reports truncation even though every expected archive byte arrived.
      if ['complete-timeout', 'corrupt-timeout', 'oversize-timeout'].include?(mode)
        body = 'x' * body.bytesize if mode == 'corrupt-timeout'
        body += 'x' if mode == 'oversize-timeout'
        length = body.bytesize + 1
      end
      if ['range', 'wrong-range', 'retry-partial'].include?(mode) && range
        File.write("#{directory}/range", range.to_s)
        status = 206
        body = body.byteslice(range..-1)
        body = 'wrong bytes' if mode == 'wrong-range'
        length = body.bytesize
      end
      body = body.byteslice(0, 3) if mode == 'retry-partial' && count < 3
      connection.write("HTTP/1.1 #{status} Fixture\r\nContent-Length: #{length}\r\nConnection: close\r\n\r\n#{body}")
    rescue IOError, SystemCallError
    ensure
      connection.close
    end
  end
end
RUBY
server_pid=$!
for _ in {1..50}; do
  [ ! -s "$work_dir/port" ] || break
  command sleep 0.1
done
[ -s "$work_dir/port" ] || php_darwin_die 'download fixture server did not start'
base=http://127.0.0.1:$(cat "$work_dir/port")
export PHP_DARWIN_MIRROR_URL="$base/good"
unset PHP_DARWIN_PREFER_MIRROR
: > "$work_dir/requests"
PHP_DARWIN_RELEASE_URL="$base/good/archive"
php_darwin_download_release_archive || php_darwin_die 'default GitHub download failed'
[ "$(cat "$work_dir/requests")" = /good/archive ] || php_darwin_die 'GitHub was not the default archive origin'
: > "$work_dir/requests"
status=$(php_darwin_fetch_release_manifest "$release_repository" "$version" "$work_dir/body" \
  "$base/good/manifest.json")
[ "$status" = 200 ] || php_darwin_die 'default GitHub manifest download failed'
[ "$(cat "$work_dir/requests")" = /good/manifest.json ] || php_darwin_die 'GitHub was not the default manifest origin'
PHP_DARWIN_RELEASE_URL="$base/moderate/archive"
: > "$work_dir/requests"
php_darwin_download_release_archive || php_darwin_die 'healthy primary download timed out'
[ "$(cat "$work_dir/requests")" = /moderate/archive ] || php_darwin_die 'healthy primary unnecessarily used the mirror'
cmp -s "$archive" "$work_dir/fixture" || php_darwin_die 'healthy primary returned invalid bytes'
for route in unavailable missing partial corrupt stall error-stall trickle; do
  PHP_DARWIN_RELEASE_URL="$base/$route/archive"
  : > "$work_dir/requests"
  download_started=$SECONDS
  php_darwin_download_release_archive || php_darwin_die "$route did not recover from the mirror"
  [ "$route" != trickle ] || [ "$((SECONDS - download_started))" -lt 60 ] || \
    php_darwin_die 'a trickling primary origin delayed mirror failover'
  cmp -s "$archive" "$work_dir/fixture" || php_darwin_die "$route retained invalid bytes"
  count=4
  [ "$route" != corrupt ] || count=2
  [ "$(wc -l < "$work_dir/requests" | tr -d ' ')" = "$count" ] || php_darwin_die "$route exceeded bounded origin retries"
done
# Resume only the missing immutable bytes; verify the final, combined digest.
export PHP_DARWIN_MIRROR_URL="$base/range"
PHP_DARWIN_RELEASE_URL="$base/partial/archive"
: > "$work_dir/requests"
: > "$work_dir/hashes"
php_darwin_download_release_archive || php_darwin_die 'partial archive did not resume'
[ "$(cat "$work_dir/hashes")" = 17 ] || php_darwin_die 'hashed incomplete bytes before resuming'
[ "$(cat "$work_dir/range")" = 5 ] || php_darwin_die 'wrong resume offset'
cmp -s "$archive" "$work_dir/fixture" || php_darwin_die 'resumed bytes differ'
[ "$(wc -l < "$work_dir/requests" | tr -d ' ')" = 4 ] || php_darwin_die 'resume exceeded bounded origin retries'
export PHP_DARWIN_MIRROR_URL="$base/wrong-range"
if php_darwin_download_release_archive; then php_darwin_die 'accepted corrupt range response'; fi
[ "$release_archive_error" = checksum ] || php_darwin_die 'corrupt resumed bytes lost their checksum error'
# A late transfer error can still contain a complete, valid archive. Corrupt
# complete and oversized responses must restart instead of requesting past EOF.
PHP_DARWIN_RELEASE_URL="$base/complete-timeout/archive"
: > "$work_dir/requests"
: > "$work_dir/hashes"
php_darwin_download_release_archive || php_darwin_die 'discarded a verified complete download'
[ "$(cat "$work_dir/hashes")" = 17 ] || php_darwin_die 'did not verify the complete errored response'
[ "$(wc -l < "$work_dir/requests" | tr -d ' ')" = 3 ] || php_darwin_die 'late transfer errors exceeded bounded retries'
export PHP_DARWIN_MIRROR_URL="$base/range"
for route in corrupt-timeout oversize-timeout; do
  PHP_DARWIN_RELEASE_URL="$base/$route/archive"
  rm -f "$work_dir/range"
  : > "$work_dir/hashes"
  php_darwin_download_release_archive || php_darwin_die "$route did not recover"
  [ ! -f "$work_dir/range" ] || php_darwin_die "$route requested a range past the archive"
  cmp -s "$archive" "$work_dir/fixture" || php_darwin_die "$route retained invalid bytes"
done
# An initial burst must not prevent a stalled transfer from failing over.
export PHP_DARWIN_MIRROR_URL="$base/good"
PHP_DARWIN_RELEASE_URL="$base/burst/archive"
download_started=$SECONDS
php_darwin_download_release_archive || php_darwin_die 'burst then stall did not recover'
[ "$((SECONDS - download_started))" -lt 60 ] || php_darwin_die 'primary exceeded its low-speed time budget'
cmp -s "$archive" "$work_dir/fixture" || php_darwin_die 'ignored range appended a full response'
# An error response must fail over on its headers, without waiting for its body.
PHP_DARWIN_RELEASE_URL="$base/error-stall/archive"
download_error_started=$(date +%s)
php_darwin_download_release_archive || php_darwin_die 'slow error body did not recover'
[ "$(( $(date +%s) - download_error_started ))" -lt 3 ] || php_darwin_die 'waited for an HTTP error response body'
export PHP_DARWIN_PREFER_MIRROR=true
export PHP_DARWIN_MIRROR_URL="$base/moderate"
: > "$work_dir/requests"
PHP_DARWIN_RELEASE_URL="$base/unavailable/archive"
php_darwin_download_release_archive || php_darwin_die 'preferred Cloudflare transfer was abandoned prematurely'
[ "$(wc -l < "$work_dir/requests" | tr -d ' ')" = 1 ] || \
  php_darwin_die 'preferred Cloudflare transfer unnecessarily fell back to GitHub'
export PHP_DARWIN_MIRROR_URL="$base/good"
: > "$work_dir/requests"
PHP_DARWIN_RELEASE_URL="$base/unavailable/archive"
php_darwin_download_release_archive || php_darwin_die 'the healthy bootstrap origin was not reused'
[ "$(wc -l < "$work_dir/requests" | tr -d ' ')" = 1 ] || php_darwin_die 'retried a known failed bootstrap origin'
export PHP_DARWIN_MIRROR_URL="$base/corrupt"
PHP_DARWIN_RELEASE_URL="$base/good/archive"
php_darwin_download_release_archive || php_darwin_die 'preferred mirror did not fall back to GitHub'
export PHP_DARWIN_PREFER_MIRROR=false
export PHP_DARWIN_MIRROR_URL="$base/good"
for route in unavailable missing partial corrupt; do
  status=$(php_darwin_fetch_release_manifest "$release_repository" "$version" "$work_dir/body" \
    "$base/$route/manifest.json")
  [ "$status" = 200 ] || php_darwin_die "$route manifest did not recover"
  cmp -s "$work_dir/body" "$work_dir/manifest" || php_darwin_die 'manifest fallback changed contents'
done
export PHP_DARWIN_MIRROR_URL="$base/missing"
for route in missing unavailable corrupt; do
  PHP_DARWIN_RELEASE_URL="$base/$route/archive"
  if php_darwin_download_release_archive; then php_darwin_die 'accepted failed origins'; fi
  case "$route" in missing) reason=not-found ;; unavailable) reason=download ;; corrupt) reason=checksum ;; esac
  [ "$release_archive_error" = "$reason" ] || php_darwin_die 'lost the original failure reason'
done
export PHP_DARWIN_MIRROR_URL="$base/partial"
status=$(php_darwin_fetch_release_manifest "$release_repository" "$version" "$work_dir/body" \
  "$base/partial/manifest.json")
[ "$status" != 200 ] || php_darwin_die 'a truncated HTTP 200 was reported as a successful manifest download'
# Recover the mirror without repeating the primary or appending a failed range
# response twice. Full archive authentication remains in the production caller.
export PHP_DARWIN_MIRROR_URL="$base/retry-partial"
PHP_DARWIN_RELEASE_URL="$base/partial/archive"
: > "$work_dir/requests"
php_darwin_download_release_archive || php_darwin_die 'mirror range retries failed'
cmp -s "$archive" "$work_dir/fixture" || php_darwin_die 'mirror retries assembled corrupt bytes'
[ "$(wc -l < "$work_dir/requests" | tr -d ' ')" = 6 ] || php_darwin_die 'mirror range retry count changed'
[ "$(cat "$work_dir/range")" = 5 ] || php_darwin_die 'mirror retries changed the requested offset'
for route in retry-http always-524 forbidden; do
  export PHP_DARWIN_MIRROR_URL="$base/$route"
  : > "$work_dir/requests"
  status=$(php_darwin_request_release "$base/$route/archive" "$work_dir/body")
  case "$route" in
    retry-http) [ "$status" = 200 ] && cmp -s "$work_dir/body" "$work_dir/fixture" ;;
    always-524) [ "$status" = 524 ] ;;
    forbidden) [ "$status" = 403 ] ;;
  esac || php_darwin_die 'mirror HTTP retry classification failed'
  count=3
  [ "$(wc -l < "$work_dir/requests" | tr -d ' ')" = "$count" ] || php_darwin_die 'unbounded error retry'
  [ ! -e "$work_dir/body.headers" ] || php_darwin_die 'mirror retry headers were not cleaned'
done
# DNS/connection failures carry no HTTP response. Simulate those exact curl
# exits before a real successful read, and verify the fallback connection limit.
export PHP_DARWIN_MIRROR_URL="$base/good"
curl() {
  local count=0 argument previous='' connect=''
  [ ! -f "$work_dir/dns-attempts" ] || count=$(cat "$work_dir/dns-attempts")
  count=$((count + 1))
  printf '%s\n' "$count" > "$work_dir/dns-attempts"
  for argument in "$@"; do
    [ "$previous" != --connect-timeout ] || connect=$argument
    previous=$argument
  done
  [ "$connect" = 10 ] || return 97
  if [ "$count" -lt 3 ]; then printf '000'; return 6; fi
  command curl "$@"
}
status=$(php_darwin_request_release "$base/good/archive" "$work_dir/body")
unset -f curl
[ "$status" = 200 ] && [ "$(cat "$work_dir/dns-attempts")" = 3 ] && \
  cmp -s "$work_dir/body" "$work_dir/fixture" || php_darwin_die 'mirror DNS retry did not recover'
export PHP_DARWIN_MIRROR_URL=
PHP_DARWIN_RELEASE_URL="$base/missing/archive"
if php_darwin_download_release_archive; then php_darwin_die 'explicit disabled mirror was ignored'; fi
[ -z "$(php_darwin_release_mirror fixture/repo 8.3)" ] || php_darwin_die 'a fork used production assets'
printf 'Verified archive and manifest failover, bounded mirror DNS/HTTP/range retries, permanent errors, truncation, stalls, checksum rejection, and disabled mirrors\n'
