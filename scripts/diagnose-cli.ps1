param([string]$Arch,[string]$Ts,[string]$Opcache)
$ErrorActionPreference='Stop'
$root=(Get-Location).Path
New-Item -ItemType Directory -Force reports | Out-Null
$report="$root/reports"
$pattern=if($Ts -eq 'nts'){"^php-.+?-nts-Win32-vs18-$Arch\.zip$"}else{"^php-(?!debug-pack-|devel-pack-|test-pack-)(?!.*-nts-).+?-Win32-vs18-$Arch\.zip$"}
$zips=@(Get-ChildItem artifacts -Recurse -Filter '*.zip' | Where-Object {$_.Name -match $pattern})
if($zips.Count -ne 1){throw 'Expected one exact runtime ZIP'}
Get-FileHash $zips[0].FullName -Algorithm SHA256 | ConvertTo-Json | Set-Content "$report/artifact.json"
Expand-Archive $zips[0].FullName runtime -Force
$php="$root/runtime/php.exe"
$env:PATH="$root/runtime;$env:PATH"
& $php -n -m | Tee-Object "$report/no-ini-modules.txt"
if($LASTEXITCODE){throw 'Bare PHP cannot start'}
$modules=Get-Content "$report/no-ini-modules.txt"
if('curl' -in $modules -or 'gd' -in $modules){throw 'The isolated startup probe must exclude curl and GD'}
$processes=@()
foreach($i in 0..5){
  $arguments="-n `"$root/tests/cli-startup-worker.php`" 250 `"$report/worker-$i.json`""
  $processes+=Start-Process -FilePath $php -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput "$report/worker-$i.stdout" -RedirectStandardError "$report/worker-$i.stderr"
}
foreach($process in $processes){$process.WaitForExit()}
$exitCodes=@($processes | ForEach-Object {$_.ExitCode})
$exitCodes | ConvertTo-Json | Set-Content "$report/worker-exits.json"
# Add diagnostics only; preserve the helper's startup behavior and failure outcome.
$helper="$root/source/sapi/cli/tests/php_cli_server.inc"
$text=Get-Content $helper -Raw
$old='echo "Server failed to start\n";'
$new='echo "Server failed to start\n"; echo "Process status: ", json_encode($status), "\n";'
if(!$text.Contains($old)){throw 'CLI helper diagnostic anchor missing'}
[IO.File]::WriteAllText($helper,$text.Replace($old,$new))
$ini="$root/runtime/diagnostic.ini"
@('[PHP]', 'date.timezone=UTC', 'allow_url_fopen=1') | Set-Content $ini
if($Opcache -eq 'opcache'){@("zend_extension=`"$root/runtime/ext/php_opcache.dll`"",'opcache.enable_cli=1') | Add-Content $ini}
$env:TEST_PHP_EXECUTABLE=$php
$env:TEST_PHP_JUNIT="$report/cli-junit.xml"
$env:NO_INTERACTION='1'
$env:REPORT_EXIT_STATUS='1'
$env:SKIP_IO_CAPTURE_TESTS='1'
Push-Location source
& $php -n run-tests.php -n -c $ini -p $php --offline --show-diff --no-progress -q -j6 sapi/cli/tests *>&1 | Tee-Object "$report/cli-suite.log"
$suiteExit=$LASTEXITCODE
Pop-Location
@{suiteExit=$suiteExit;workerExitCodes=$exitCodes} | ConvertTo-Json | Set-Content "$report/outcome.json"
Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=(Get-Date).AddMinutes(-30)} -ErrorAction SilentlyContinue |
  Where-Object {$_.Message -match 'php\.exe|php8.*\.dll'} |
  Select-Object TimeCreated,Id,ProviderName,Message | ConvertTo-Json -Depth 4 | Set-Content "$report/windows-application-events.json"
if($suiteExit -ne 0 -or ($exitCodes | Where-Object {$_ -ne 0})){throw 'Startup probe or CLI suite reproduced a failure; inspect retained diagnostics'}
