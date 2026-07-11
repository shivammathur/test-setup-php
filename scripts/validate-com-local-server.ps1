param(
    [Parameter(Mandatory = $true)]
    [string] $PhpDirectory,
    [Parameter(Mandatory = $true)]
    [string] $TestPackDirectory,
    [Parameter(Mandatory = $true)]
    [string] $ServerDirectory,
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,
    [int] $Iterations = 20
)

$ErrorActionPreference = 'Stop'
$php = Join-Path $PhpDirectory 'php.exe'
$runner = Join-Path $TestPackDirectory 'run-tests.php'
$sourceTest = Join-Path $TestPackDirectory 'ext\com_dotnet\tests\bug64130.phpt'
$server = Join-Path $ServerDirectory 'comlocal.exe'
$directProbe = Join-Path $PSScriptRoot '..\tests\com-local-server.php'
$work = Join-Path $OutputDirectory 'tests'
$logDirectory = Join-Path $OutputDirectory 'logs'
New-Item -Path $work -ItemType Directory -Force | Out-Null
New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null

foreach ($path in @($php, $runner, $sourceTest, $server, $directProbe)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required path was not found: $path"
    }
}

$sourceHash = (Get-FileHash -LiteralPath $sourceTest -Algorithm SHA256).Hash
$duplicates = 1..12 | ForEach-Object {
    $path = Join-Path $work ("bug64130-{0:D2}.phpt" -f $_)
    Copy-Item -LiteralPath $sourceTest -Destination $path
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $sourceHash) {
        throw "Copied PHPT differs from upstream: $path"
    }
    $path
}

$env:REPORT_EXIT_STATUS = '1'
$env:NO_INTERACTION = '1'
$env:TEST_PHP_EXECUTABLE = $php
$env:PHPRC = $PhpDirectory
$loadJobs = @()
$results = [System.Collections.Generic.List[object]]::new()

try {
    & $server /RegServer
    if ($LASTEXITCODE -ne 0) {
        throw "COM server registration failed with exit code $LASTEXITCODE"
    }

    & reg.exe query 'HKCU\Software\Classes\InternetExplorer.Application\CLSID' /reg:32 |
        Tee-Object -FilePath (Join-Path $OutputDirectory 'registry.txt')
    if ($LASTEXITCODE -ne 0) {
        throw 'The 32-bit InternetExplorer.Application override was not registered.'
    }

    $probeOutput = & $php -n -d "extension_dir=$PhpDirectory\ext" -d extension=php_com_dotnet.dll $directProbe 2>&1
    $probeOutput | Tee-Object -FilePath (Join-Path $OutputDirectory 'direct-probe.txt')
    if ($LASTEXITCODE -ne 0) {
        throw "Direct COM probe failed with exit code $LASTEXITCODE"
    }

    # Exceed the four logical processors on the hosted runners while run-tests
    # starts six workers, matching the condition that destabilizes legacy IE.
    $loadJobs = 1..6 | ForEach-Object {
        Start-Job -ScriptBlock {
            $end = [DateTime]::UtcNow.AddMinutes(45)
            while ([DateTime]::UtcNow -lt $end) {
                $null = [Math]::Sqrt((Get-Random -Minimum 1 -Maximum 1000000))
            }
        }
    }

    for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
        $log = Join-Path $logDirectory ("iteration-{0:D2}.log" -f $iteration)
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $lines = & $php -n $runner -p $php -n -c (Join-Path $PhpDirectory 'php.ini') -q --show-diff --set-timeout 60 -j6 @duplicates 2>&1
        $exitCode = $LASTEXITCODE
        $timer.Stop()
        $text = $lines -join "`n"
        $text | Set-Content -LiteralPath $log -Encoding UTF8

        $passes = ([regex]::Matches($text, '(?m)^PASS ')).Count
        $skips = ([regex]::Matches($text, '(?m)^SKIP ')).Count
        $failures = ([regex]::Matches($text, '(?m)^FAIL ')).Count
        $borks = ([regex]::Matches($text, '(?m)^BORK ')).Count
        $status = if ($exitCode -eq 0 -and $passes -eq $duplicates.Count -and $skips -eq 0 -and $failures -eq 0 -and $borks -eq 0) {
            'PASS'
        } else {
            'FAIL'
        }

        $results.Add([pscustomobject]@{
            Iteration = $iteration
            Status = $status
            ExitCode = $exitCode
            Passes = $passes
            Skips = $skips
            Failures = $failures
            Borks = $borks
            ElapsedMilliseconds = $timer.ElapsedMilliseconds
        })
        Write-Host "iteration=$iteration status=$status pass=$passes skip=$skips fail=$failures bork=$borks elapsed_ms=$($timer.ElapsedMilliseconds)"
    }

    if ((Get-FileHash -LiteralPath $sourceTest -Algorithm SHA256).Hash -ne $sourceHash) {
        throw 'The upstream bug64130.phpt changed during validation.'
    }

    $results | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'results.csv') -NoTypeInformation
    $results | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'results.json') -Encoding UTF8
    $results | Format-Table -AutoSize | Tee-Object -FilePath (Join-Path $OutputDirectory 'summary.txt')

    $failed = @($results | Where-Object Status -NE 'PASS')
    if ($failed.Count -ne 0) {
        throw "$($failed.Count) of $Iterations saturated local COM server iterations failed."
    }
} finally {
    $loadJobs | Stop-Job -ErrorAction SilentlyContinue
    $loadJobs | Remove-Job -Force -ErrorAction SilentlyContinue
    & $server /Shutdown 2>$null
    Start-Sleep -Milliseconds 500
    & $server /UnregServer 2>$null
}
