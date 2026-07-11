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
$sourceTest = Join-Path $PSScriptRoot '..\tests\bug64130.phpt'
$comTests = Join-Path $TestPackDirectory 'ext\com_dotnet\tests'
$work = Join-Path $OutputDirectory 'stress-tests'
$logDirectory = Join-Path $OutputDirectory 'stress-logs'
New-Item -Path $work -ItemType Directory -Force | Out-Null
New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null

$env:REPORT_EXIT_STATUS = '1'
$env:NO_INTERACTION = '1'
$env:TEST_PHP_EXECUTABLE = $php
$env:PHPRC = $PhpDirectory
$results = [System.Collections.Generic.List[object]]::new()

function Invoke-Scenario {
    param(
        [string] $Name,
        [string[]] $Tests,
        [int] $Iterations,
        [switch] $Parallel,
        [switch] $CpuLoad
    )

    $log = Join-Path $logDirectory "$Name.log"
    $loadJobs = @()
    if ($CpuLoad) {
        $loadJobs = 1..6 | ForEach-Object {
            Start-Job -ScriptBlock {
                $end = [DateTime]::UtcNow.AddMinutes(20)
                while ([DateTime]::UtcNow -lt $end) {
                    $null = [Math]::Sqrt((Get-Random -Minimum 1 -Maximum 1000000))
                }
            }
        }
    }

    try {
        for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
            $arguments = @('-n', $runner, '-p', $php, '-n', '-c', $ini, '-q', '--show-diff', '--set-timeout', '60')
            if ($Parallel) {
                $arguments += '-j6'
            }
            $arguments += $Tests

            $before = @(Get-Process -Name iexplore -ErrorAction SilentlyContinue).Count
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            $lines = & $php @arguments 2>&1
            $exitCode = $LASTEXITCODE
            $timer.Stop()
            $text = $lines -join "`n"
            $after = @(Get-Process -Name iexplore -ErrorAction SilentlyContinue).Count
            $failures = ([regex]::Matches($text, '(?m)^FAIL ')).Count
            $borks = ([regex]::Matches($text, '(?m)^BORK ')).Count
            $passes = ([regex]::Matches($text, '(?m)^PASS ')).Count
            $skips = ([regex]::Matches($text, '(?m)^SKIP ')).Count
            $status = if ($failures -gt 0 -or $borks -gt 0 -or $exitCode -ne 0) { 'FAIL' } else { 'PASS' }

            @(
                "===== iteration=$iteration status=$status exit=$exitCode elapsed_ms=$($timer.ElapsedMilliseconds) ie_before=$before ie_after=$after pass=$passes skip=$skips fail=$failures bork=$borks ====="
                $text
                ''
            ) | Add-Content -LiteralPath $log -Encoding UTF8

            $results.Add([pscustomobject]@{
                Scenario = $Name
                Iteration = $iteration
                Status = $status
                ExitCode = $exitCode
                Passes = $passes
                Skips = $skips
                Failures = $failures
                Borks = $borks
                ElapsedMilliseconds = $timer.ElapsedMilliseconds
                IeProcessesBefore = $before
                IeProcessesAfter = $after
            })
        }
    } finally {
        $loadJobs | Stop-Job -ErrorAction SilentlyContinue
        $loadJobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

$baseline = Join-Path $work 'baseline.phpt'
Copy-Item -LiteralPath $sourceTest -Destination $baseline

# One test, both through the normal runner and through its worker protocol.
Invoke-Scenario -Name 'serial_single' -Tests @($baseline) -Iterations 30
Invoke-Scenario -Name 'parallel_runner_single' -Tests @($baseline) -Iterations 30 -Parallel

# The actual COM test directory exercises other COM objects around bug64130.
$comTestPaths = @(Get-ChildItem -LiteralPath $comTests -Filter '*.phpt' | Select-Object -ExpandProperty FullName)
Invoke-Scenario -Name 'parallel_com_suite' -Tests $comTestPaths -Iterations 10 -Parallel

# Force simultaneous InternetExplorer.Application activation through six workers.
$duplicateDirectory = Join-Path $work 'duplicates'
New-Item -Path $duplicateDirectory -ItemType Directory -Force | Out-Null
$duplicateTests = 1..12 | ForEach-Object {
    $path = Join-Path $duplicateDirectory ("bug64130-{0:D2}.phpt" -f $_)
    Copy-Item -LiteralPath $sourceTest -Destination $path
    $path
}
Invoke-Scenario -Name 'parallel_duplicate_ie' -Tests $duplicateTests -Iterations 15 -Parallel

# Match the full extension suite's CPU contention without changing the PHPT.
Invoke-Scenario -Name 'serial_single_cpu_load' -Tests @($baseline) -Iterations 30 -CpuLoad

$results | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'stress-results.csv') -NoTypeInformation
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'stress-results.json') -Encoding UTF8
$results |
    Group-Object Scenario |
    ForEach-Object {
        [pscustomobject]@{
            Scenario = $_.Name
            PASS = @($_.Group | Where-Object Status -EQ 'PASS').Count
            FAIL = @($_.Group | Where-Object Status -EQ 'FAIL').Count
            AverageMilliseconds = [math]::Round(($_.Group | Measure-Object ElapsedMilliseconds -Average).Average, 1)
            MaximumMilliseconds = ($_.Group | Measure-Object ElapsedMilliseconds -Maximum).Maximum
        }
    } |
    Format-Table -AutoSize |
    Tee-Object -FilePath (Join-Path $OutputDirectory 'stress-summary.txt')

