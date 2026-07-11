param(
    [Parameter(Mandatory = $true)]
    [string] $PhpDirectory,
    [Parameter(Mandatory = $true)]
    [string] $TestPackDirectory,
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$php = Join-Path $PhpDirectory 'php.exe'
$runner = Join-Path $TestPackDirectory 'run-tests.php'
$ini = Join-Path $PhpDirectory 'php.ini'
$comTests = Join-Path $TestPackDirectory 'ext\com_dotnet\tests'
$bugTest = Join-Path $comTests 'bug64130.phpt'
$logDirectory = Join-Path $OutputDirectory 'logs'
$loadDirectory = Join-Path $OutputDirectory 'load-tests'
New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
New-Item -Path $loadDirectory -ItemType Directory -Force | Out-Null

$content = Get-Content -LiteralPath $bugTest -Raw
if ($content -notmatch '(?m)^--CONFLICTS--$') {
    $content = $content.Replace("--SKIPIF--", "--CONFLICTS--`nall`n--SKIPIF--")
    Set-Content -LiteralPath $bugTest -Value $content -NoNewline -Encoding UTF8
}

$loadTemplate = @'
--TEST--
Synthetic CPU load
--FILE--
<?php
$end = microtime(true) + 0.25;
$value = 'load';
while (microtime(true) < $end) {
    $value = hash('sha256', $value, true);
}
echo "done\n";
?>
--EXPECT--
done
'@

$loadTests = 1..60 | ForEach-Object {
    $path = Join-Path $loadDirectory ("load-{0:D2}.phpt" -f $_)
    Set-Content -LiteralPath $path -Value $loadTemplate -NoNewline -Encoding UTF8
    $path
}

$env:REPORT_EXIT_STATUS = '1'
$env:NO_INTERACTION = '1'
$env:TEST_PHP_EXECUTABLE = $php
$env:PHPRC = $PhpDirectory
$results = [System.Collections.Generic.List[object]]::new()

function Invoke-Validation {
    param(
        [string] $Name,
        [string[]] $Tests,
        [int] $Iterations
    )

    $log = Join-Path $logDirectory "$Name.log"
    for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
        $arguments = @('-n', $runner, '-p', $php, '-n', '-c', $ini, '-q', '--show-diff', '--set-timeout', '60', '-j6') + $Tests
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $lines = & $php @arguments 2>&1
        $exitCode = $LASTEXITCODE
        $timer.Stop()
        $text = $lines -join "`n"
        $bugPassed = $text -match '(?m)^PASS Bug #64130 '
        $bugFailed = $text -match '(?m)^FAIL Bug #64130 '
        $status = if ($bugPassed -and -not $bugFailed) { 'PASS' } else { 'FAIL' }
        $sequentialMarker = $text -match 'Scheduling 1 tests for sequential execution'

        @(
            "===== iteration=$iteration status=$status exit=$exitCode sequential_marker=$sequentialMarker elapsed_ms=$($timer.ElapsedMilliseconds) ====="
            $text
            ''
        ) | Add-Content -LiteralPath $log -Encoding UTF8

        $results.Add([pscustomobject]@{
            Scenario = $Name
            Iteration = $iteration
            Status = $status
            ExitCode = $exitCode
            SequentialMarker = $sequentialMarker
            ElapsedMilliseconds = $timer.ElapsedMilliseconds
        })
    }
}

$comTestPaths = @(Get-ChildItem -LiteralPath $comTests -Filter '*.phpt' | Select-Object -ExpandProperty FullName)
Invoke-Validation -Name 'parallel_com_suite_conflict' -Tests $comTestPaths -Iterations 30
Invoke-Validation -Name 'synthetic_cpu_suite_conflict' -Tests ($loadTests + $bugTest) -Iterations 20

$results | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'conflict-results.csv') -NoTypeInformation
$results |
    Group-Object Scenario |
    ForEach-Object {
        [pscustomobject]@{
            Scenario = $_.Name
            PASS = @($_.Group | Where-Object Status -EQ 'PASS').Count
            FAIL = @($_.Group | Where-Object Status -EQ 'FAIL').Count
            SequentialMarkers = @($_.Group | Where-Object SequentialMarker).Count
            AverageMilliseconds = [math]::Round(($_.Group | Measure-Object ElapsedMilliseconds -Average).Average, 1)
            MaximumMilliseconds = ($_.Group | Measure-Object ElapsedMilliseconds -Maximum).Maximum
        }
    } |
    Format-Table -AutoSize |
    Tee-Object -FilePath (Join-Path $OutputDirectory 'conflict-summary.txt')

$global:LASTEXITCODE = 0
