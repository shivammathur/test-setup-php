$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
New-Item reports -ItemType Directory -Force | Out-Null
$dumpDirectory=(New-Item dumps -ItemType Directory -Force).FullName
# CI hosts suppress fault reporting through the inherited process error mode.
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class CrashReporting { [DllImport("kernel32.dll")] public static extern uint GetErrorMode(); [DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint mode); }'
$previousMode=[CrashReporting]::GetErrorMode()
$null=[CrashReporting]::SetErrorMode($previousMode -band [uint32]4294967293)
@{previous=$previousMode;current=[CrashReporting]::GetErrorMode()} | ConvertTo-Json | Set-Content reports/error-mode.json
Set-Service WerSvc -StartupType Manual
Start-Service WerSvc
$archive=Join-Path $env:RUNNER_TEMP 'procdump.zip'
Invoke-WebRequest 'https://download.sysinternals.com/files/Procdump.zip' -OutFile $archive
$tools=Join-Path $env:RUNNER_TEMP 'procdump'
Expand-Archive $archive $tools -Force
$proc=Join-Path $tools 'procdump.exe'
$signature=Get-AuthenticodeSignature $proc
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'Invalid ProcDump signature' }
& $proc -accepteula -ma -i $dumpDirectory
if ($LASTEXITCODE -ne 0) { throw 'Post-mortem debugger installation failed' }
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug' | Select-Object PSPath,Auto,Debugger | ConvertTo-Json | Set-Content reports/postmortem-config.json
$zip=@(Get-ChildItem artifacts -Filter 'php-*-nts-*-x86.zip' | Where-Object { $_.Name -notmatch 'debug-pack|devel-pack|test-pack' })
if ($zip.Count -ne 1) { throw 'Ambiguous canary runtime' }
$canary=Join-Path $env:RUNNER_TEMP 'dump-canary'
Expand-Archive $zip[0].FullName $canary -Force
Copy-Item "$canary/php.exe" "$canary/php-dump-check.exe"
# Keep diagnostics from inheriting authentication material.
Get-ChildItem Env: | Where-Object { $_.Name -match '(?i)(token|secret|password|credential|authorization)' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
$start=[Diagnostics.ProcessStartInfo]::new("$canary/php-dump-check.exe")
$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
foreach ($arg in @('-n','-d',"extension_dir=$canary/ext",'-d','extension=zend_test','-r','zend_test_crash();')) { $start.ArgumentList.Add($arg) }
$process=[Diagnostics.Process]::new();$process.StartInfo=$start;$null=$process.Start()
$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit(60000)) { $process.Kill($true);throw 'Post-mortem canary did not exit' }
$found=@(Get-ChildItem dumps -Filter 'php-dump-check*.dmp')
@{exitCode=$process.ExitCode;dumps=$found.Count;stdout=$out.GetAwaiter().GetResult();stderr=$err.GetAwaiter().GetResult()} | ConvertTo-Json | Set-Content reports/dump-canary.json
$process.Dispose()
if (-not $found.Count) { Get-Content reports/dump-canary.json; Get-Content reports/error-mode.json; throw 'Post-mortem capture did not produce a canary dump' }
$found | Remove-Item -Force
Write-Host 'Verified post-mortem crash capture; no debugger attaches before a crash.'
