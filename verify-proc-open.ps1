param([Parameter(Mandatory)][string]$Phase, [switch]$ExpectFailure)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:REPORT_EXIT_STATUS = '1'
$php = $env:PHP_TEST_BINARY
if (-not (Test-Path $php)) { throw 'Compiled PHP binary is missing' }
$env:TEST_PHP_EXECUTABLE = $php
$env:TEST_PHP_CGI_EXECUTABLE = ''
$env:TEST_PHPDBG_EXECUTABLE = ''
$tests = @(
    'ext/standard/tests/general_functions/proc_open_null.phpt',
    'ext/standard/tests/general_functions/proc_open_redirect.phpt'
)
$modes = @{
    'no-ini' = @('-n', 'run-tests.php', '-n', '-d', 'precision=12')
    'opcache' = @('-n', 'run-tests.php', '-n', '-d', "zend_extension=$env:PHP_TEST_OPCACHE", '-d', 'opcache.enable_cli=1', '-d', 'opcache.protect_memory=1', '-d', 'opcache.jit_buffer_size=64M', '-d', 'opcache.jit=tracing')
}

foreach ($mode in @('no-ini', 'opcache')) {
    $resultDir = "results/$Phase/$mode"
    New-Item -ItemType Directory -Force $resultDir | Out-Null
    $phpArgs = $modes[$mode] + @('-q', '--no-progress', '--no-color', '--show-diff') + $tests
    & $php @phpArgs 2>&1 | Tee-Object -FilePath "$resultDir/run.log"
    $testExitCode = $LASTEXITCODE
    $log = Get-Content "$resultDir/run.log" -Raw
    foreach ($test in $tests) {
        foreach ($suffix in @('.out', '.diff', '.exp', '.log')) {
            $artifact = [IO.Path]::ChangeExtension($test, $suffix)
            if (Test-Path $artifact) { Copy-Item $artifact $resultDir }
        }
    }

    if ($ExpectFailure) {
        if ($testExitCode -ne 1 -or $log -notmatch 'Tests failed\s*:\s*2\s') {
            throw "Expected exactly two failures and exit code 1; got exit code $testExitCode"
        }
        foreach ($test in $tests) {
            $name = [IO.Path]::GetFileName($test)
            if ($log -notmatch ('(?m)^FAIL .*' + [regex]::Escape($name))) {
                throw "Missing expected failure for $name"
            }
            $output = Get-Content ([IO.Path]::ChangeExtension($test, '.out')) -Raw
            if (-not $output.Contains('unexpected string content "echo"')) {
                throw "Failure for $name was not the expected quoting parse error"
            }
        }
        $summary = "$Phase / $mode`: reproduced both Windows quoting failures (exit $testExitCode)"
    } else {
        if ($testExitCode -ne 0 -or $log -notmatch 'Tests passed\s*:\s*2\s' -or $log -notmatch 'Tests failed\s*:\s*0\s') {
            throw "Expected both tests to pass; got exit code $testExitCode"
        }
        $summary = "$Phase / $mode`: both tests passed (exit $testExitCode)"
    }
    Write-Output $summary
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content $env:GITHUB_STEP_SUMMARY "- $summary" }
}
$global:LASTEXITCODE = 0
