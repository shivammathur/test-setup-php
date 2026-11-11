#!/usr/bin/env bash
# Observe the published installer without changing the action or archive bytes.
bash() {
  local status started ended log
  if [ "${repo:-}" != php-darwin ] || [ "${1:-}" != /tmp/install.sh ]; then
    command bash "$@"
    return $?
  fi
  started=$(python3 -c 'import time; print(time.monotonic_ns())')
  log="${RUNNER_TEMP:?}/php-darwin-setup-install-${INSTALL_PHASE:?}.log"
  if command bash "$@" > "$log" 2>&1; then status=0; else status=$?; fi
  ended=$(python3 -c 'import time; print(time.monotonic_ns())')
  python3 - "$started" "$ended" "$status" <<'PY'
import json, os, platform, sys
record = dict(php=os.environ['PHP_VERSION'], architecture=platform.machine(),
              phase=os.environ['INSTALL_PHASE'], packs=os.environ['PHP_DARWIN_REQUIRE_PACKS']=='true', status=int(sys.argv[3]),
              installer_seconds=round((int(sys.argv[2])-int(sys.argv[1]))/1e9, 3))
with open(os.path.join(os.environ['RUNNER_TEMP'], 'install-timings.jsonl'), 'a') as out:
    out.write(json.dumps(record) + '\n')
PY
  cat "$log"
  # Do not let setup-php hide a broken ARM cache by building PHP from source.
  if [ "$status" -ne 0 ]; then exit "$status"; fi
  return "$status"
}
