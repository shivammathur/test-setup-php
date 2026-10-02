param([string]$Php, [string]$Arch, [string]$Ts)
$ErrorActionPreference = 'Stop'
$started = Get-Date
$row = @((Get-Content recheck-manifest.json -Raw | ConvertFrom-Json).php | Where-Object php -EQ $Php)[0]
$runtime = @($row.runtimeZips | Where-Object { $_.arch -eq $Arch -and $_.ts -eq $Ts })[0]
New-Item reports, reports/dumps, minimal, unpacked, symbols, source-tests -ItemType Directory -Force | Out-Null
$workspace = (Get-Location).Path
Start-Transcript reports/transcript.txt
$headers = @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/vnd.github+json' }
$api = 'https://api.github.com/repos/shivammathur/php-windows-builder'
$a = Invoke-RestMethod "$api/actions/artifacts/$($row.artifactId)" -Headers $headers
if ($a.workflow_run.id -ne $row.runId -or $a.expired -or $a.name -ne 'artifacts') { throw 'Wrong candidate artifact' }
Invoke-WebRequest "$api/actions/artifacts/$($row.artifactId)/zip" -Headers $headers -OutFile merged.zip
if ((Get-FileHash merged.zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $row.artifactSha256) { throw 'Merged artifact changed' }
Expand-Archive merged.zip unpacked -Force
$zip = Join-Path unpacked $runtime.name
if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $runtime.sha256) { throw 'Runtime artifact changed' }
Expand-Archive $zip runtime -Force
$coreDll = if ($Ts -eq 'ts') { 'php8ts.dll' } else { 'php8.dll' }
foreach ($file in @('php.exe', 'php-cgi.exe', $coreDll)) { Copy-Item "runtime/$file" minimal }
$files = @(Get-ChildItem minimal -File | ForEach-Object { @{ name=$_.Name; sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } })
Expand-Archive (Join-Path unpacked ($runtime.name -replace '^php-', 'php-debug-pack-')) symbols -Force
Invoke-WebRequest "https://api.github.com/repos/php/php-src/zipball/$($row.sourceCommit)" -Headers $headers -OutFile source.zip
Expand-Archive source.zip source-download -Force
$sourceRoot = @(Get-ChildItem source-download -Directory)
if ($sourceRoot.Count -ne 1) { throw 'Unexpected source archive layout' }
Get-ChildItem $sourceRoot[0].FullName -Force | Move-Item -Destination source-tests
if (!(Test-Path source-tests/run-tests.php)) { throw 'Pinned source test runner is missing' }

# Collect postmortem evidence on the disposable runner without injecting a debugger into the process.
$dumpDirectory = (Resolve-Path reports/dumps).Path
foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\Windows Error Reporting\LocalDumps')) {
    foreach ($exe in @('php.exe', 'php-cgi.exe')) {
        $key = Join-Path $hive $exe
        New-Item $key -Force | Out-Null
        New-ItemProperty $key -Name DumpFolder -PropertyType ExpandString -Value $dumpDirectory -Force | Out-Null
        New-ItemProperty $key -Name DumpCount -PropertyType DWord -Value 5 -Force | Out-Null
        New-ItemProperty $key -Name DumpType -PropertyType DWord -Value 2 -Force | Out-Null
    }
}
$phpExe = (Resolve-Path minimal/php.exe).Path
$cgiExe = (Resolve-Path minimal/php-cgi.exe).Path
# Keep CI credentials out of child-process memory and the diagnostic dumps.
foreach ($credential in @(Get-ChildItem Env: | Where-Object Name -Match '(?i)TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE_KEY')) {
    Remove-Item "Env:$($credential.Name)"
}
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
$env:PHP_INI_SCAN_DIR = ''
$env:PHPRC = (Resolve-Path minimal).Path
$env:TEST_PHP_EXECUTABLE = $phpExe
$env:TEST_PHP_CGI_EXECUTABLE = $cgiExe
$env:TEST_PHP_ARGS = '-n'
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
$env:SKIP_ONLINE_TESTS = '1'
$starts = @()
foreach ($exe in @($phpExe, $cgiExe)) {
    for ($i=1; $i -le 300; $i++) {
        $p = [System.Diagnostics.Process]::new()
        $p.StartInfo.FileName = $exe
        $p.StartInfo.ArgumentList.Add('-n')
        $p.StartInfo.ArgumentList.Add('-v')
        $p.StartInfo.UseShellExecute = $false
        $p.StartInfo.RedirectStandardOutput = $true
        $p.StartInfo.RedirectStandardError = $true
        $null = $p.Start()
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        if (!$p.WaitForExit(30000)) { $p.Kill(); throw 'Startup probe timed out' }
        $exitCode = $p.ExitCode
        $record = @{ exe=(Split-Path $exe -Leaf); iteration=$i; exit=$exitCode }
        if ($exitCode -ne 0) { $record.stdout=$stdout.GetAwaiter().GetResult(); $record.stderr=$stderr.GetAwaiter().GetResult(); Write-Host "Startup failure: $($record | ConvertTo-Json -Compress)" }
        $starts += $record
        $p.Dispose()
    }
}
$starts | ConvertTo-Json -Depth 6 | Set-Content reports/startups.json
$tests = @('sapi/cli/tests/gh18582.phpt', 'sapi/cli/tests/bug65633.phpt', 'sapi/cli/tests/gh22003.phpt', 'sapi/cgi/tests/004.phpt', 'sapi/cgi/tests/bug78323.phpt', 'ext/standard/tests/file/windows_mb_path/test_long_path_1.phpt')
$reports = @()
Push-Location source-tests
try {
    for ($i=1; $i -le 30; $i++) {
        $env:TEST_PHP_JUNIT = Join-Path $workspace "reports/minimal-$i.xml"
        & $phpExe -n run-tests.php -p $phpExe -n -q --offline --show-diff @tests 2>&1 | Tee-Object (Join-Path $workspace "reports/minimal-$i.log") | Out-Host
        if (Test-Path $env:TEST_PHP_JUNIT) {
            [xml]$xml = Get-Content $env:TEST_PHP_JUNIT -Raw
            $reports += @{ iteration=$i; cases=@($xml.SelectNodes('//testcase')).Count; failures=@($xml.SelectNodes('//failure|//error')).Count; skipped=@($xml.SelectNodes('//skipped')).Count }
        } else { $reports += @{ iteration=$i; missingReport=$true; exit=$LASTEXITCODE } }
    }
} finally { Pop-Location }
Start-Sleep -Seconds 5
Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$started} -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -in @('Application Error','Windows Error Reporting') } |
    Select-Object TimeCreated, Id, ProviderName, Message | ConvertTo-Json -Depth 10 | Set-Content reports/application-events.json
$debuggers = @(Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits" -Filter cdb.exe -Recurse -ErrorAction SilentlyContinue)
$debuggers.FullName | Set-Content reports/debugger-paths.txt
$cdb = @($debuggers | Where-Object { $_.Directory.Name -eq $Arch }) | Select-Object -First 1
if ($cdb) {
    $symbolPath = (Resolve-Path symbols).Path + ';srv*' + (Join-Path $workspace symbol-cache) + '*https://msdl.microsoft.com/download/symbols'
    foreach ($dump in Get-ChildItem reports/dumps -Filter '*.dmp') {
        & $cdb.FullName -z $dump.FullName -y $symbolPath -c '.ecxr; kpn; lm; q' 2>&1 | Set-Content (Join-Path reports ($dump.Name + '.txt'))
    }
}
$result = @{ php=$Php; arch=$Arch; ts=$Ts; sourceRunId=$row.runId; sourceCommit=$row.sourceCommit; runtimeSha256=$runtime.sha256; minimalFiles=$files; startupFailures=@($starts | Where-Object exit -NE 0); reports=$reports; dumps=@(Get-ChildItem reports/dumps -Filter '*.dmp' | ForEach-Object Name) }
$result | ConvertTo-Json -Depth 20 | Set-Content reports/minimal-results.json
Stop-Transcript
if ($result.startupFailures.Count -gt 0 -or @($reports | Where-Object { $_.failures -gt 0 -or $_.missingReport -or $_.cases -ne $tests.Count -or $_.skipped -gt 0 }).Count -gt 0) { throw 'Minimal runtime diagnostics require review; see retained evidence' }
