@echo off
pushd %GITHUB_WORKSPACE%\.validation
cl /nologo /W4 /WX /O2 /MT null-probe.c /Fe:null-probe.exe
if errorlevel 1 exit /b 3
popd
exit /b 0
