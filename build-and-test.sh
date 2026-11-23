#!/usr/bin/env bash
set -euo pipefail

revision=$1
workspace=$(pwd)
build=$(mktemp -d /tmp/opcache-lock-build.XXXXXX)
mkdir -p "$workspace/evidence"
cp php-ref.txt "$workspace/evidence/"
case "$(uname -s)" in
    SunOS)
        export PATH="/usr/gnu/bin:/usr/bin:$PATH"
        export PKG_CONFIG_PATH=/usr/lib/amd64/pkgconfig
        make_cmd=gmake
        jobs=2
        ;;
    *)
        # Exercise the same autoconf branch on systems with a native flock().
        export ac_cv_func_flock=no
        make_cmd="make"
        if command -v nproc >/dev/null; then jobs=$(nproc); else jobs=8; fi
        ;;
esac
cd "$build"
tar -xzf "$workspace/php-src.tar.gz" --strip-components=1
python3 "$workspace/observe.py" instrument "$build"
./buildconf > buildconf.log 2>&1 || { tail -100 buildconf.log; exit 1; }
CC=gcc CFLAGS='-O0 -g0' ./configure --disable-all --disable-cgi --disable-phpdbg \
    --disable-opcache-jit --enable-pcntl > configure.log 2>&1 || { tail -100 configure.log; exit 1; }
{
    uname -a
    grep 'checking for flock' configure.log
    grep 'HAVE_FLOCK' main/php_config.h
} | tee "$workspace/evidence/configuration.txt"
grep -Fq '/* #undef HAVE_FLOCK */' main/php_config.h
"$make_cmd" -j"$jobs" sapi/cli/php > make.log 2>&1 || { tail -100 make.log; exit 1; }
sapi/cli/php -n -v
python3 "$workspace/observe.py" "$revision" "$build" "$workspace/evidence"
