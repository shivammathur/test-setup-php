@echo off
setlocal
cd /d C:\OEM
set /p REPORT=<report-url.txt
curl.exe -fsS --retry 3 -X POST --data-binary "Windows setup reached the test" "%REPORT%/start"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File C:\OEM\test.ps1 > C:\OEM\transcript.log 2>&1
set RC=%errorlevel%
curl.exe -fsS --retry 3 --data-binary "@C:\OEM\transcript.log" "%REPORT%/log"
curl.exe -fsS --retry 3 --data-binary "%RC%" "%REPORT%/done"
if exist \\host.lan\Data\ (
  copy /y C:\OEM\transcript.log \\host.lan\Data\transcript.log
  echo %RC%>\\host.lan\Data\done
)
