#!/usr/bin/env bash
set -euo pipefail
mode=$1
workspace=$(pwd)
evidence="$workspace/evidence"
build=$(mktemp -d /tmp/session-fd.XXXXXX)
export PATH="/usr/gnu/bin:/usr/bin:$PATH"
export PKG_CONFIG_PATH=/usr/lib/amd64/pkgconfig
cd "$build"
tar -xzf "$workspace/php-src.tar.gz"
./buildconf > buildconf.log 2>&1 || { tail -80 buildconf.log; exit 1; }
CC=gcc CFLAGS='-O0 -g0' ./configure --disable-all --disable-cgi --disable-phpdbg \
    --disable-opcache-jit --enable-session --enable-pcntl > configure.log 2>&1 || { tail -80 configure.log; exit 1; }
gmake -j2 sapi/cli/php > make.log 2>&1 || { tail -80 make.log; exit 1; }
php="$build/sapi/cli/php"
{
    uname -a
    "$php" -n -v
    gcc -dM -E -include fcntl.h - </dev/null | grep -E '^#define (F_SETFD|FD_CLOEXEC|O_CLOEXEC) '
} | tee "$evidence/platform.txt"
python3 - "$php" "$mode" <<'PY' | tee "$evidence/compiled-path.txt"
from pathlib import Path
import sys
binary = Path(sys.argv[1]).read_bytes()
has_fallback = b'fcntl(%d, F_SETFD, FD_CLOEXEC) failed:' in binary
print('Session F_SETFD fallback compiled:', has_fallback)
assert has_fallback == (sys.argv[2] == 'fallback')
PY

mkdir -m 700 sessions
touch sessions/sess_cloexec-check
chmod 600 sessions/sess_cloexec-check
/usr/bin/truss -o "$evidence/session.truss" "$php" -n -d session.save_handler=files \
    -d session.save_path="$build/sessions" "$workspace/session-exec.php" | tee "$evidence/exec.txt"
grep -Fxq 'Session file descriptor closed across exec' "$evidence/exec.txt"
python3 - "$evidence" <<'PY' | tee "$evidence/session-syscalls.txt"
from pathlib import Path
import re, sys
evidence = Path(sys.argv[1])
fd = re.search(r'open as fd (\d+) before exec', (evidence / 'exec.txt').read_text()).group(1)
for line in (evidence / 'session.truss').read_text(errors='replace').splitlines():
    if 'sess_cloexec-check' in line or re.search(r'\bfcntl\w*\(\s*' + fd + r'\s*,', line):
        print(line)
PY

tests=(ext/session/tests/session_create_id_basic.phpt ext/session/tests/session_id_basic.phpt
       ext/session/tests/session_id_basic2.phpt ext/session/tests/session_save_path_basic.phpt
       ext/session/tests/session_write_close_basic.phpt)
"$php" -n run-tests.php -n -p "$php" --offline --no-progress "${tests[@]}" > "$evidence/phpt.log" 2>&1 || { tail -50 "$evidence/phpt.log"; exit 1; }
tail -13 "$evidence/phpt.log"
grep -Eq '^Tests passed[[:space:]]*:[[:space:]]*5[[:space:]]' "$evidence/phpt.log"
