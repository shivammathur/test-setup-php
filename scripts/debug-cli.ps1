param([string]$Arch,[string]$Ts)
$ErrorActionPreference='Stop'
$root=(Get-Location).Path
$candidates=@("${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\$Arch\cdb.exe", "$env:ProgramFiles\Windows Kits\10\Debuggers\$Arch\cdb.exe")
$cdb=$candidates | Where-Object {Test-Path $_} | Select-Object -First 1
if(!$cdb){
  $installer="$env:RUNNER_TEMP/winsdksetup.exe"
  Invoke-WebRequest 'https://go.microsoft.com/fwlink/?linkid=2243390' -OutFile $installer
  $install=Start-Process $installer -ArgumentList '/features OptionId.WindowsDesktopDebuggers /quiet /norestart /ceip off' -Wait -PassThru
  if($install.ExitCode -notin @(0,3010)){throw 'Debugger installation failed'}
  $cdb=$candidates | Where-Object {Test-Path $_} | Select-Object -First 1
}
if(!$cdb){throw 'CDB is unavailable'}
$pattern=if($Ts -eq 'nts'){"^php-debug-pack-.+?-nts-Win32-vs18-$Arch\.zip$"}else{"^php-debug-pack-(?!.*-nts-).+?-Win32-vs18-$Arch\.zip$"}
$packs=@(Get-ChildItem artifacts -Recurse -Filter '*.zip' | Where-Object {$_.Name -match $pattern})
if($packs.Count -ne 1){throw 'Expected exactly one matching symbol ZIP'}
Get-FileHash $packs[0].FullName -Algorithm SHA256 | ConvertTo-Json | Set-Content reports/symbol-artifact.json
Expand-Archive $packs[0].FullName symbols -Force
$symbolDirs=@("$root/symbols")+@(Get-ChildItem symbols -Directory -Recurse | Select-Object -ExpandProperty FullName)
$symbolPath=($symbolDirs -join ';')+";srv*$env:RUNNER_TEMP/symbol-cache*https://msdl.microsoft.com/download/symbols"
# Only text exception/stack/module metadata leaves the runner; no process dumps.
@('sxd -c2 ".echo UNHANDLED_PHP_ACCESS_VIOLATION; .exr -1; .ecxr; k; lm; q" av', 'sxn cpr', 'sxn epr', 'g') | Set-Content reports/debug-commands.txt
# Match the concurrent reproducer and preserve the normal heap (-hd).
# The previous serial debugger run did not reproduce the bare-process failures.
$debuggers=@()
foreach($i in 0..5){
  $arguments="-hd -o -g -G -cf `"$root/reports/debug-commands.txt`" -y `"$symbolPath`" -logo `"$root/reports/core-stack-$i.log`" `"$root/runtime/php.exe`" -n `"$root/tests/cli-startup-worker.php`" 1000 `"$root/reports/debug-worker-$i.json`""
  $debuggers+=Start-Process -FilePath $cdb -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput "$root/reports/debugger-$i.stdout" -RedirectStandardError "$root/reports/debugger-$i.stderr"
}
foreach($debugger in $debuggers){$debugger.WaitForExit()}
$failures=@()
foreach($i in 0..5){
  if(Select-String -Path "reports/core-stack-$i.log" -Pattern '^UNHANDLED_PHP_ACCESS_VIOLATION\s*$' -Quiet){$failures+='Captured an unhandled PHP core access violation'}
  if(!(Test-Path "reports/debug-worker-$i.json")){$failures+="Debug worker $i did not complete";continue}
  $result=Get-Content "reports/debug-worker-$i.json" -Raw | ConvertFrom-Json
  if(@($result.cases).Count -ne 1000 -or @($result.cases | Where-Object {!$_.passed}).Count){$failures+="Debug worker $i reported failed startup cases"}
}
if($failures.Count){throw ($failures -join '; ')}
