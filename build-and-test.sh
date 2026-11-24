#!/usr/bin/env bash
set -euo pipefail
variant=$1
workspace=$(pwd)
build=$(mktemp -d /tmp/php-lock-compare.XXXXXX)
export PATH="/usr/gnu/bin:/usr/bin:$PATH"
export PKG_CONFIG_PATH=/usr/lib/amd64/pkgconfig
cd "$build"
tar -xzf "$workspace/php-src.tar.gz"
python3 "$workspace/observe.py" instrument "$build"
./buildconf > buildconf.log 2>&1 || { tail -100 buildconf.log; exit 1; }
CC=gcc CFLAGS='-O0 -g0' ./configure --disable-all --disable-cgi --disable-phpdbg \
    --disable-opcache-jit --enable-session --enable-pcntl > configure.log 2>&1 || { tail -100 configure.log; exit 1; }
{
    uname -a
    grep 'checking for flock' configure.log
    grep 'HAVE_FLOCK' main/php_config.h
    gcc -dM -E -include fcntl.h - < /dev/null | grep ' O_CLOEXEC '
} | tee "$workspace/evidence/configuration.txt"
grep -Fq '/* #undef HAVE_FLOCK */' main/php_config.h
gmake -j2 sapi/cli/php > make.log 2>&1 || { tail -100 make.log; exit 1; }
sapi/cli/php -n -v
mkdir sessions
sapi/cli/php -n -d session.save_handler=files -d session.save_path="$build/sessions" \
    "$workspace/session-exec.php" | tee "$workspace/evidence/session-exec.txt"
python3 "$workspace/observe.py" "$variant" "$build" "$workspace/evidence"
