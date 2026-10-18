#!/usr/bin/env bash
set -euo pipefail
mkdir -p reports
pids=()
while read -r name url; do
  (
    for attempt in {1..12}; do
      if curl -fsSL --connect-timeout 10 --max-time 20 "$url" -o "reports/$name.sh" && cmp -s cache/scripts/install.sh "reports/$name.sh"; then
        sha256sum "reports/$name.sh"
        exit 0
      fi
      echo "Waiting for $name to serve the published installer (attempt $attempt)"
      sleep 5
    done
    exit 1
  ) >"reports/$name.log" 2>&1 &
  pids+=("$!")
done <<'EOF'
github https://github.com/shivammathur/php-ubuntu/releases/download/builds/install.sh
github-latest https://github.com/shivammathur/php-ubuntu/releases/latest/download/install.sh
raw-main https://raw.githubusercontent.com/shivammathur/php-ubuntu/main/scripts/install.sh
jsdelivr https://cdn.jsdelivr.net/gh/shivammathur/php-ubuntu@main/scripts/install.sh
setup-php https://setup-php.com/php-ubuntu/install.sh
artifacts-php-ubuntu https://artifacts.php-ubuntu.setup-php.com/install.sh
artifacts-setup-php https://artifacts.setup-php.com/php-ubuntu/install.sh
cloudsmith https://dl.cloudsmith.io/public/shivammathur/php-ubuntu/raw/files/php-ubuntu.sh
EOF
result=0
for pid in "${pids[@]}"; do
  wait "$pid" || result=1
done
cat reports/*.log
exit "$result"
