param([ValidateSet('baseline', 'fixed')][string] $Variant)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = $env:GITHUB_WORKSPACE
$evidence = Join-Path $root 'evidence'
$paths = Get-Content (Join-Path $evidence 'paths.json') -Raw | ConvertFrom-Json
$env:PATH = "$($paths.oci);$(Split-Path $paths.php);$env:PATH"
$env:PDO_TEST_DIR = Join-Path $paths.source 'ext/pdo/tests'
$env:REDIR_TEST_DIR = $env:PDO_TEST_DIR + '/'
$env:PDOTEST_DSN = 'oci:dbname=localhost:1521/XEPDB1.localdomain;charset=AL32UTF8'
$env:PDOTEST_USER = 'system'
$env:PDOTEST_PASS = 'oracle'
$env:PDO_OCI_TEST_DSN = $env:PDOTEST_DSN
$env:PDO_OCI_TEST_USER = $env:PDOTEST_USER
$env:PDO_OCI_TEST_PASS = $env:PDOTEST_PASS
$env:TEST_PHP_EXECUTABLE = $paths.php
$env:TEST_PHP_ARGS = "-n -d extension=$($paths.dll) -d opcache.enable_cli=0"
$env:REPORT_EXIT_STATUS = '1'
$env:NO_INTERACTION = '1'
$phpArgs = @('-n', '-d', "extension=$($paths.dll)", '-d', 'opcache.enable_cli=0')
$smoke = 'new PDO(getenv("PDOTEST_DSN"), getenv("PDOTEST_USER"), getenv("PDOTEST_PASS")); echo "CONNECTED";'
$ready = $false
foreach ($attempt in 1..30) {
    $output = & $paths.php @phpArgs -r $smoke 2>&1
    if ($LASTEXITCODE -eq 0 -and "$output" -eq 'CONNECTED') { $ready = $true; break }
    Start-Sleep -Seconds 2
}
if (!$ready) { throw "Oracle connection failed: $output" }
$testsDir = Join-Path $evidence 'tests'
New-Item -ItemType Directory -Force $testsDir | Out-Null
$testNames = @(1, 3, 5 | ForEach-Object { "pdo_fetch_class_change_ctor_args_during_fetch$_.phpt" })
foreach ($name in $testNames) { Copy-Item (Join-Path $env:PDO_TEST_DIR $name) $testsDir }
Copy-Item (Join-Path $root 'debug/pdo_oci_statement_gc.phpt') $testsDir
$testNames += 'pdo_oci_statement_gc.phpt'
$tests = @($testNames | ForEach-Object { Join-Path $testsDir $_ })
$runTests = Join-Path $paths.source 'run-tests.php'
Write-Host 'Starting selected PHPT tests'
& $paths.php -n $runTests -q --offline --show-diff --set-timeout 120 -j1 @tests 2>&1 |
    Tee-Object -FilePath (Join-Path $evidence 'phpt.log') | Write-Host
$phptExit = $LASTEXITCODE
Write-Host "PHPT exit code: $phptExit"

function Invoke-CapturedProcess([string] $Exe, [string[]] $Arguments, [string] $Prefix) {
    $start = [Diagnostics.ProcessStartInfo]::new($Exe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void] $process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(180000)) {
        $process.Kill($true)
        throw "Process timed out: $Exe"
    }
    $stdout.Result | Set-Content "$Prefix.stdout.log"
    $stderr.Result | Set-Content "$Prefix.stderr.log"
    return $process.ExitCode
}

$results = @()
foreach ($test in $tests) {
    $name = [IO.Path]::GetFileNameWithoutExtension($test)
    Write-Host "Tracing $name"
    $caseDir = Join-Path $evidence $name
    New-Item -ItemType Directory -Force $caseDir | Out-Null
    $contents = Get-Content $test -Raw
    $file = [regex]::Match($contents, '(?ms)^--FILE--\r?\n(.*?)(?=^--[A-Z_]+--\r?$)').Groups[1].Value
    if (!$file) { throw "Missing FILE section: $name" }
    $script = Join-Path $caseDir 'test.php'
    $file | Set-Content $script -Encoding utf8NoBOM
    $clean = [regex]::Match($contents, '(?ms)^--CLEAN--\r?\n(.*?)(?=^--[A-Z_]+--\r?$)').Groups[1].Value
    $cleanScript = Join-Path $caseDir 'clean.php'
    if ($clean) { $clean | Set-Content $cleanScript -Encoding utf8NoBOM }
    if ($clean) { & $paths.php @phpArgs $cleanScript | Out-Null }
    $plainExit = Invoke-CapturedProcess $paths.php ($phpArgs + $script) (Join-Path $caseDir 'plain')
    if ($clean) { & $paths.php @phpArgs $cleanScript | Out-Null }

    $dump = (Join-Path $caseDir 'crash.dmp').Replace('\', '/')
    $crashCommands = Join-Path $caseDir 'crash.txt'
    @"
.echo FATAL_ACCESS_VIOLATION
.exr -1
.ecxr
kv 40
~* kb 12
lmv m php*
lmv m oci
.dump /ma $dump
q
"@ | Set-Content $crashCommands -Encoding ascii
    $commands = Join-Path $caseDir 'commands.txt'
    $crashScript = $crashCommands.Replace('\', '/')
    @'
.symopt+ 0x10
sxd -c2 "$$><CRASH_SCRIPT" av
sxe -c ".echo PROCESS_EXIT; .lastevent; q" epr
bu php_pdo_oci!oci_handle_closer ".echo DB_CLOSE; r rcx; dt php_pdo_oci!pdo_dbh_t @rcx driver_data is_persistent; k 8; gc"
bu php_pdo_oci!oci_stmt_dtor ".echo STMT_DTOR; r rcx; dt php_pdo_oci!pdo_stmt_t @rcx dbh driver_data; k 8; gc"
bu oci!OCIHandleFree ".if (@rdx == 1) {.echo OCI_ENV_FREE; r rcx; k 8; }; gc"
g
'@.Replace('CRASH_SCRIPT', $crashScript) | Set-Content $commands -Encoding ascii
    $symbolDirs = @($paths.symbols) + @(Get-ChildItem $paths.symbols -Directory -Recurse | ForEach-Object FullName) + @((Split-Path $paths.dll))
    $symbolPath = $symbolDirs -join ';'
    $debugArgs = @('-hd', '-y', $symbolPath, '-lines', '-cf', $commands, $paths.php) + $phpArgs + $script
    $debugExit = Invoke-CapturedProcess $paths.cdb $debugArgs (Join-Path $caseDir 'debugger')
    $trace = Get-Content (Join-Path $caseDir 'debugger.stdout.log') -Raw
    $crashed = $trace.Contains('FATAL_ACCESS_VIOLATION')
    $normalExit = $trace -match 'Exit process.*code 0\b'
    $entry = [ordered]@{
        test=$name; plainExit=$plainExit; debuggerExit=$debugExit; fatalAccessViolation=$crashed
        normalDebuggerExit=$normalExit; dumpExists=(Test-Path (Join-Path $caseDir 'crash.dmp'))
        connectionBreakpoint=$trace.Contains("`nDB_CLOSE"); statementBreakpoint=$trace.Contains("`nSTMT_DTOR")
    }
    $results += $entry
    $entry | ConvertTo-Json | Write-Host
    if ($clean) { & $paths.php @phpArgs $cleanScript | Out-Null }
}
[ordered]@{variant=$Variant; php=$paths.version; ts=$paths.ts; phptExit=$phptExit; tests=$results} |
    ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'results.json')
$invalid = @($results | Where-Object { !$_.fatalAccessViolation -and !$_.normalDebuggerExit })
if ($invalid.Count) { throw 'Debugger did not record a fatal AV or clean process exit for every test' }
if (@($results | Where-Object { !$_.connectionBreakpoint -or !$_.statementBreakpoint }).Count) { throw 'Cleanup breakpoints did not resolve for every test' }
if ($Variant -eq 'fixed' -and ($phptExit -ne 0 -or @($results | Where-Object { $_.plainExit -ne 0 -or $_.fatalAccessViolation }).Count)) {
    throw 'The fixed branch failed validation'
}
if ($Variant -eq 'baseline' -and $paths.version.StartsWith('8.6.') -and $paths.ts -eq 'ts' -and
    @($results | Where-Object { $_.test -like 'pdo_fetch_class*' -and $_.fatalAccessViolation -and $_.dumpExists }).Count -eq 0) {
    throw 'The original 8.6 TS failure was not captured under the debugger'
}
