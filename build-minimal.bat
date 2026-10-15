@echo off
if not exist C:\php-proc-open-deps mkdir C:\php-proc-open-deps
call buildconf.bat --force > build.log 2>&1
if errorlevel 1 goto failed
call configure.bat --disable-all --enable-cli --enable-zts --enable-opcache --enable-opcache-jit --disable-cgi --disable-phpdbg --disable-test-ini --without-analyzer --with-php-build=C:\php-proc-open-deps --enable-object-out-dir=C:\php-proc-open-build >> build.log 2>&1
if errorlevel 1 goto failed
nmake /NOLOGO >> build.log 2>&1
if errorlevel 1 goto failed
exit /b 0
:failed
type build.log
exit /b 1
