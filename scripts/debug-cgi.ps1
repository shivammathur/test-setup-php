param([Parameter(Mandatory)] [string] $Branch, [Parameter(Mandatory)] [ValidateSet('x86','x64')] [string] $Arch)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = (Get-Location).Path
$entry = @(Get-Content debug-manifest.json -Raw | ConvertFrom-Json | Where-Object { $_.branch -eq $Branch -and $_.arch -eq $Arch })
if ($entry.Count -ne 1) { throw 'Ambiguous debug manifest entry' }
$entry = $entry[0]
$report = (New-Item reports -ItemType Directory -Force).FullName
$dumps = (New-Item "$report/dumps" -ItemType Directory -Force).FullName
$phpRoot = Join-Path $env:RUNNER_TEMP 'debug-php'
$symbols = Join-Path $env:RUNNER_TEMP 'php-symbols'
foreach ($item in @(@{name=$entry.runtime; sha=$entry.runtimeSha256; destination=$phpRoot}, @{name=$entry.debugPack; sha=$entry.debugSha256; destination=$symbols})) {
    $zip = Join-Path "$root/artifacts" $item.name
    if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.sha) { throw "Archive checksum mismatch: $($item.name)" }
    Expand-Archive $zip $item.destination -Force
}
$php = Join-Path $phpRoot 'php-cgi.exe'
$env:PATH = "$phpRoot;$env:PATH"
$cdb = Join-Path ${env:ProgramFiles(x86)} "Windows Kits/10/Debuggers/$Arch/cdb.exe"
if (-not (Test-Path $cdb)) { throw "CDB not installed: $cdb" }
$symbolPath = "$symbols;$phpRoot;srv*$env:RUNNER_TEMP/microsoft-symbols*https://msdl.microsoft.com/download/symbols"
$fixture = Join-Path $report 'cgi-startup.php'
'<?php header("Content-Type: text/plain"); echo "CGI_STARTUP_OK";' | Set-Content $fixture
$settings = @('-n','-d',"extension_dir=$phpRoot/ext",'-d','extension=zend_test','-d','opcache.enable_cli=1','-d','opcache.jit_buffer_size=64M','-d','opcache.jit=tracing','-d','opcache.record_warnings=1')
if (Test-Path "$phpRoot/ext/php_opcache.dll") { $settings += @('-d','zend_extension=opcache') }
$arguments = $settings + @($fixture)
$entry | ConvertTo-Json -Depth 5 | Set-Content "$report/provenance.json"
@{cdb=$cdb; debuggerVersion=(Get-Item $cdb).VersionInfo.FileVersion; arguments=$arguments; symbolPath=$symbolPath} | ConvertTo-Json -Depth 5 | Set-Content "$report/debug-settings.json"
# Capture the unchanged concurrent workload first; analyze its unhandled crashes with CDB.
foreach ($view in [Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    $wer = $base.CreateSubKey('SOFTWARE\Microsoft\Windows\Windows Error Reporting')
    $wer.SetValue('DontShowUI',1,[Microsoft.Win32.RegistryValueKind]::DWord); $wer.Dispose()
    $key = $base.CreateSubKey('SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\php-cgi.exe')
    $key.SetValue('DumpFolder',$dumps,[Microsoft.Win32.RegistryValueKind]::ExpandString)
    $key.SetValue('DumpType',2,[Microsoft.Win32.RegistryValueKind]::DWord)
    $key.SetValue('DumpCount',2,[Microsoft.Win32.RegistryValueKind]::DWord)
    $key.Dispose(); $base.Dispose()
}
function Start-CapturedProcess([string] $Exe, [string[]] $Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($Exe)
    $info.UseShellExecute=$false; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($key in @($info.Environment.Keys)) {
        if ($key -match '(?i)TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTHORIZATION') { $null=$info.Environment.Remove($key) }
    }
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
    $null=$process.Start()
    return @{process=$process; stdout=$process.StandardOutput.ReadToEndAsync(); stderr=$process.StandardError.ReadToEndAsync()}
}
$launches=[Collections.Generic.List[object]]::new()
for ($batch=0; $batch -lt 32; $batch++) {
    $processes = @(1..64 | ForEach-Object { Start-CapturedProcess $php $arguments })
    foreach ($item in $processes) {
        $p=$item.process
        $timedOut=-not $p.WaitForExit(120000)
        if ($timedOut) { $p.Kill($true); $p.WaitForExit() }
        $stdout=$item.stdout.GetAwaiter().GetResult(); $stderr=$item.stderr.GetAwaiter().GetResult()
        $launches.Add(@{batch=$batch; pid=$p.Id; exitCode=$p.ExitCode; timedOut=$timedOut; stdout=$stdout; stderr=$stderr})
        $p.Dispose()
    }
    $launches | ConvertTo-Json -Depth 5 | Set-Content "$report/launches.json"
    Write-Host "Batch $batch; launches=$($launches.Count); failures=$(@($launches | Where-Object { $_.exitCode -ne 0 }).Count); dumps=$(@(Get-ChildItem $dumps -Filter '*.dmp').Count)"
    if (@(Get-ChildItem $dumps -Filter '*.dmp').Count) { break }
}
# A custom exception handler can prevent WER capture. Run directly under CDB if needed.
if (-not @(Get-ChildItem $dumps -Filter '*.dmp').Count) {
    for ($batch=0; $batch -lt 128; $batch++) {
        $processes = @(1..16 | ForEach-Object {
            $label = "live-$batch-$_"
            $dump = Join-Path $dumps "$label.dmp"
            $commandFile = Join-Path $report "$label.commands.txt"
            ('sxd -c2 ".echo CRASH_CAPTURED; .dump /ma ' + $dump + '; .exr -1; .ecxr; kv; q" av; g') | Set-Content $commandFile
            $capture = Start-CapturedProcess $cdb (@('-hd','-G','-cf',$commandFile,$php) + $arguments)
            $capture.label=$label
            $capture
        })
        foreach ($item in $processes) {
            $p=$item.process
            if (-not $p.WaitForExit(120000)) { $p.Kill($true); $p.WaitForExit() }
            $output=$item.stdout.GetAwaiter().GetResult()+$item.stderr.GetAwaiter().GetResult()
            if ($output -match 'CRASH_CAPTURED|error|failed' -or -not $output.Contains('CGI_STARTUP_OK')) { $output | Set-Content "$report/$($item.label).log" }
            Remove-Item "$report/$($item.label).commands.txt"
            $p.Dispose()
        }
        if (@(Get-ChildItem $dumps -Filter '*.dmp').Count) { break }
    }
}
$analyses=[Collections.Generic.List[object]]::new()
foreach ($dump in Get-ChildItem $dumps -Filter '*.dmp') {
    $log=Join-Path $report ($dump.BaseName+'.stack.txt')
    $commands='.symopt+0x410; .reload /f; !analyze -v; .exr -1; .ecxr; kv; ~*kb; r; dv /t /v; ub @$ip; u @$ip; lmv m php8; lmv m php_cgi; q'
    $capture=Start-CapturedProcess $cdb @('-z',$dump.FullName,'-y',$symbolPath,'-srcpath',"$root/source",'-c',$commands)
    $p=$capture.process
    if (-not $p.WaitForExit(600000)) { $p.Kill($true); $p.WaitForExit(); throw 'CDB dump analysis timed out' }
    $output=$capture.stdout.GetAwaiter().GetResult()+$capture.stderr.GetAwaiter().GetResult()
    $output | Set-Content $log
    $analyses.Add(@{dump=$dump.Name; dumpSha256=(Get-FileHash $dump.FullName -Algorithm SHA256).Hash; stack=[IO.Path]::GetFileName($log); debuggerExitCode=$p.ExitCode; hasAccessViolation=($output -match '(?i)c0000005'); hasPhpSymbols=($output -match 'php8!\w+')})
    $p.Dispose()
}
@{branch=$Branch; arch=$Arch; sourceRun=$entry.run; sourceSha=$entry.sourceSha; launches=$launches.Count; failures=@($launches | Where-Object { $_.exitCode -ne 0 }); analyses=$analyses.ToArray()} | ConvertTo-Json -Depth 8 | Set-Content "$report/summary.json"
if (-not $analyses.Count -or -not @($analyses | Where-Object { $_.hasAccessViolation -and $_.hasPhpSymbols }).Count) { throw 'No symbolized access-violation stack captured' }
