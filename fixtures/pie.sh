#!/usr/bin/env bash
set -e
mkdir -p artifacts
trap 'cp /tmp/pie-*.log artifacts/ 2>/dev/null || true' EXIT
if [ "$PIE_CHANNEL" = nightly ]; then
  add_tool https://php.github.io/pie/pie.phar pie '-V'
fi
if [ "$TARGET_PHP" != 8.0 ]; then
  node fixtures/pie-timing.cjs start binary
  pie_install fastjson 0.10.2 false
  node fixtures/pie-timing.cjs end binary
  cp /tmp/pie-fastjson.log artifacts/pie-binary.log
  php fixtures/pie-verify.php fastjson 0.10.2
  pie_file=$(command -v pie)
  sudo mv "$pie_file" "$pie_file.saved"
  node fixtures/pie-timing.cjs start loaded
  pie_install fastjson 'iliaal/fastjson:0.10.2' false
  node fixtures/pie-timing.cjs end loaded
  [ ! -e "$pie_file" ] || { echo 'Loaded extension caused a PIE download'; exit 1; }
  sudo mv "$pie_file.saved" "$pie_file"
  if pie_install fastjson 'iliaal/fastjson:99.99.99' false; then
    echo 'Wrong installed version incorrectly satisfied a pin'; exit 1
  fi
  php fixtures/pie-verify.php fastjson 0.10.2
  disable_extension_helper fastjson true
  sudo rm -f /tmp/php"$version"_extensions
  node fixtures/pie-timing.cjs start reenable
  pie_install fastjson 'iliaal/fastjson:0.10.2' false
  node fixtures/pie-timing.cjs end reenable
  php fixtures/pie-verify.php fastjson 0.10.2
fi
node fixtures/pie-timing.cjs start source_blocked
if pie_install apcu 'apcu/apcu:5.1.28' false; then
  echo 'Source-only extension unexpectedly installed'; exit 1
fi
node fixtures/pie-timing.cjs end source_blocked
grep -q 'all possible download URL methods were suppressed' /tmp/pie-apcu.log
! check_extension apcu
if [ "$TARGET_PHP" = 8.0 ]; then
  grep -q 'Target PHP installation:.*8.0.' /tmp/pie-apcu.log
  [ -x "$tool_path_dir/pie-cli" ]
  node fixtures/pie-timing.cjs start source_allowed
  pie_install apcu 'apcu/apcu:5.1.28' true
  node fixtures/pie-timing.cjs end source_allowed
  php fixtures/pie-verify.php apcu 5.1.28
fi
printf 'PIE Unix checks passed\n'
