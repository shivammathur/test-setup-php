param(
    [Parameter(Mandatory = $true)]
    [string] $PhpDirectory,
    [Parameter(Mandatory = $true)]
    [string] $TestPackDirectory,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 32)]
    [int] $Workers,
    [Parameter(Mandatory = $true)]
    [int] $Replica,
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$php = Join-Path $PhpDirectory 'php.exe'
$ini = Join-Path $PhpDirectory 'php.ini'
$runner = Join-Path $TestPackDirectory 'run-tests.php'
$comDirectory = Join-Path $TestPackDirectory 'ext\com_dotnet\tests'
$bugTest = Join-Path $comDirectory 'bug64130.phpt'
$testPaths = @(Get-ChildItem -LiteralPath $comDirectory -Filter '*.phpt' | Sort-Object FullName | Select-Object -ExpandProperty FullName)
$results = [System.Collections.Generic.List[object]]::new()
$log = Join-Path $OutputDirectory 'worker-sweep.log'

$bugContent = Get-Content -LiteralPath $bugTest -Raw
if ($bugContent -match '(?m)^--CONFLICTS--') {
    throw 'The worker sweep requires the unmodified upstream bug64130.phpt without a CONFLICTS section.'
}

[pscustomobject]@{
    ImageOS = $env:ImageOS
    ImageVersion = $env:ImageVersion
    Workers = $Workers
    Replica = $Replica
    ProcessorCount = [Environment]::ProcessorCount
    Bug64130Sha256 = (Get-FileHash -LiteralPath $bugTest -Algorithm SHA256).Hash
    TestCount = $testPaths.Count
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'metadata.json') -Encoding utf8

$env:REPORT_EXIT_STATUS = '1'
$env:NO_INTERACTION = '1'
$env:TEST_PHP_EXECUTABLE = $php
$env:PHPRC = $PhpDirectory

for ($iteration = 1; $iteration -le 50; $iteration++) {
    $arguments = @(
        '-n',
        $runner,
        '-p', $php,
        '-n',
        '-c', $ini,
        '-q',
        '--show-diff',
        '--set-timeout', '60',
        "-j$Workers"
    ) + $testPaths

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lines = & $php @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $timer.Stop()
    $text = $lines -join "`n"
    $bugFailed = $text -match '(?m)^FAIL Bug #64130 '
    $bugPassed = $text -match '(?m)^PASS Bug #64130 '
    $allFailures = ([regex]::Matches($text, '(?m)^FAIL ')).Count
    $allBorks = ([regex]::Matches($text, '(?m)^BORK ')).Count

    @(
        "===== workers=$Workers replica=$Replica iteration=$iteration exit=$exitCode elapsed_ms=$($timer.ElapsedMilliseconds) bug_pass=$bugPassed bug_fail=$bugFailed failures=$allFailures borks=$allBorks ====="
        $text
        ''
    ) | Add-Content -LiteralPath $log -Encoding utf8

    $results.Add([pscustomobject]@{
        ImageOS = $env:ImageOS
        ImageVersion = $env:ImageVersion
        Workers = $Workers
        Replica = $Replica
        Iteration = $iteration
        BugPassed = $bugPassed
        BugFailed = $bugFailed
        ExitCode = $exitCode
        AllFailures = $allFailures
        AllBorks = $allBorks
        ElapsedMilliseconds = $timer.ElapsedMilliseconds
    })
}

$results | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'worker-sweep.csv') -NoTypeInformation
[pscustomobject]@{
    ImageOS = $env:ImageOS
    ImageVersion = $env:ImageVersion
    Workers = $Workers
    Replica = $Replica
    Iterations = $results.Count
    BugPasses = @($results | Where-Object BugPassed).Count
    BugFailures = @($results | Where-Object BugFailed).Count
    OtherFailingIterations = @($results | Where-Object { $_.AllFailures -gt [int]$_.BugFailed }).Count
    AverageMilliseconds = [math]::Round(($results | Measure-Object ElapsedMilliseconds -Average).Average, 1)
    MaximumMilliseconds = ($results | Measure-Object ElapsedMilliseconds -Maximum).Maximum
} | Format-List | Tee-Object -FilePath (Join-Path $OutputDirectory 'worker-sweep-summary.txt')

$global:LASTEXITCODE = 0

