#!/usr/bin/env bash
set -eo pipefail
. /etc/os-release
test "$VERSION_ID" = 22.04
src="$GITHUB_WORKSPACE/v2/src"
. "$src/scripts/unix.sh"
. "$src/scripts/tools/ppa.sh"
debug=release
runner=github
if ! check_ppa ondrej/php; then add_ppa ondrej/php || check_ppa ondrej/php; fi
apt-get indextargets --no-release-info --format '$(REPO_URI)' | grep -E 'ondrej/php/ubuntu' >/dev/null
if [[ "$CACHE" = published ]]; then exit 0; fi
# Only the unpublished archive is served locally. Each action fetches its normal installer.
sudo install -d /var/tmp/php80-sury-qa
sudo install -m 755 qa/curl /usr/local/sbin/curl
test "$(sudo sh -c 'command -v curl')" = /usr/local/sbin/curl
python3 -m http.server 18760 --bind 127.0.0.1 --directory "$GITHUB_WORKSPACE/builder/builds" > "$RUNNER_TEMP/qa-http.log" 2>&1 </dev/null &
for attempt in {1..15}; do
  if /usr/bin/curl -fsSI 'http://127.0.0.1:18760/php_8.0-nts+ubuntu22.04.tar.zst' >/dev/null; then exit 0; fi
  sleep 1
done
exit 1
