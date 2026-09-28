#!/usr/bin/env bash
set -uo pipefail
phase=$1
extension_dir=$2
report_dir="$GITHUB_WORKSPACE/diagnostics/$phase"
mkdir -p "$report_dir"
exec > >(tee "$report_dir/report.txt") 2>&1

echo "Phase: $phase, cache-extensions: $CACHE_VERSION, attempt: $GITHUB_RUN_ATTEMPT"
sw_vers
brew --version
ls -ld /opt/homebrew/Cellar/firebird* /opt/homebrew/opt/firebird* 2>/dev/null || true
find /opt/homebrew/Cellar -path '*firebird*' -name '*fbclient*' -ls 2>/dev/null || true

if [ "$phase" = dependencies ]; then
  cache_dir="$RUNNER_TOOL_CACHE/deps/pdo_firebird"
  if [ -f "$cache_dir/list" ]; then
    cp "$cache_dir/list" "$report_dir/dependency-list.txt"
    cat "$cache_dir/list"
    while IFS= read -r dependency; do
      echo "Archive: $dependency"
      gtar -I zstd -tvf "$cache_dir/$dependency.tar.zst" > "$report_dir/$dependency.contents.txt" 2>&1
      status=$?
      echo "Archive status: $status; entries: $(wc -l < "$report_dir/$dependency.contents.txt")"
      if [ "$dependency" = 'firebird-client@3' ]; then
        cat "$report_dir/$dependency.contents.txt"
      fi
    done < "$cache_dir/list"
  fi
fi

if [ -f "$extension_dir/pdo_firebird.so" ]; then
  ls -l "$extension_dir/pdo_firebird.so"
  shasum -a 256 "$extension_dir/pdo_firebird.so"
  otool -L "$extension_dir/pdo_firebird.so"
fi

PHASE="$phase" EXTENSION_DIR="$extension_dir" REPORT_DIR="$report_dir" python3 - <<'PY'
import json, os, re
from pathlib import Path
root = Path('/opt/homebrew/etc/php/7.4')
files = [root / 'php.ini', *sorted((root / 'conf.d').glob('*.ini'))]
directives = []
for path in files:
    if path.is_file():
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if re.match(r'\s*(zend_)?extension\s*=', line, re.I) and 'pdo_firebird' in line.lower():
                directives.append({'file': str(path), 'line': number, 'text': line})
library = Path('/opt/homebrew/opt/firebird-client@3/lib/libfbclient.dylib')
report = {
    'phase': os.environ['PHASE'],
    'library_exists': library.exists(),
    'library_path': str(library.resolve()),
    'extension_exists': (Path(os.environ['EXTENSION_DIR']) / 'pdo_firebird.so').exists(),
    'directives': directives,
}
Path(os.environ['REPORT_DIR'], 'state.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
PY

if [ "$phase" = final ]; then
  php --ini > "$report_dir/php-ini.txt" 2>&1
  cat "$report_dir/php-ini.txt"
  php -r 'echo "pdo_firebird=" . (extension_loaded("pdo_firebird") ? "loaded" : "missing") . PHP_EOL;' > "$report_dir/php-startup.txt" 2>&1
  cat "$report_dir/php-startup.txt"
fi
