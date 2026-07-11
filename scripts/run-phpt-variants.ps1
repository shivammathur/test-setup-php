param(
    [Parameter(Mandatory = $true)]
    [string] $PhpDirectory,
    [Parameter(Mandatory = $true)]
    [string] $TestPackDirectory,
    [Parameter(Mandatory = $false)]
    [int] $Iterations = 12,
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$php = Join-Path $PhpDirectory 'php.exe'
$runner = Join-Path $TestPackDirectory 'run-tests.php'
$ini = Join-Path $PhpDirectory 'php.ini'
$sourceTest = Join-Path $PSScriptRoot '..\tests\bug64130.phpt'
$variantDirectory = Join-Path $OutputDirectory 'variants'
$logDirectory = Join-Path $OutputDirectory 'logs'
New-Item -Path $variantDirectory -ItemType Directory -Force | Out-Null
New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null

if (-not (Test-Path -LiteralPath $runner)) {
    throw "run-tests.php was not found at $runner"
}

$original = Get-Content -LiteralPath $sourceTest -Raw
$quitMarker = '$ie->quit();'

$variants = @(
    [pscustomobject]@{ Name = 'baseline'; Cleanup = $quitMarker; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'sleep_50'; Cleanup = "$quitMarker`nusleep(50000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'sleep_100'; Cleanup = "$quitMarker`nusleep(100000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'sleep_250'; Cleanup = "$quitMarker`nusleep(250000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'sleep_500'; Cleanup = "$quitMarker`nusleep(500000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'sleep_1000'; Cleanup = "$quitMarker`nusleep(1000000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'sleep_2000'; Cleanup = "$quitMarker`nusleep(2000000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'unset'; Cleanup = "$quitMarker`nunset(`$ie);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'unset_gc'; Cleanup = "$quitMarker`nunset(`$ie);`ngc_collect_cycles();"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'unset_gc_50'; Cleanup = "$quitMarker`nunset(`$ie);`ngc_collect_cycles();`nusleep(50000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'unset_gc_100'; Cleanup = "$quitMarker`nunset(`$ie);`ngc_collect_cycles();`nusleep(100000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'unset_gc_250'; Cleanup = "$quitMarker`nunset(`$ie);`ngc_collect_cycles();`nusleep(250000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'unset_gc_500'; Cleanup = "$quitMarker`nunset(`$ie);`ngc_collect_cycles();`nusleep(500000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'unset_gc_1000'; Cleanup = "$quitMarker`nunset(`$ie);`ngc_collect_cycles();`nusleep(1000000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'unset_gc_2000'; Cleanup = "$quitMarker`nunset(`$ie);`ngc_collect_cycles();`nusleep(2000000);"; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'wait_iexplore_exit'; Cleanup = @'
$ie->quit();
unset($ie);
gc_collect_cycles();
$deadline = microtime(true) + 10;
do {
    $processes = [];
    exec('tasklist /FI "IMAGENAME eq iexplore.exe" /NH', $processes);
    $running = false;
    foreach ($processes as $process) {
        if (stripos($process, 'iexplore.exe') !== false) {
            $running = true;
            break;
        }
    }
    if (!$running) {
        break;
    }
    usleep(50000);
} while (microtime(true) < $deadline);
'@; RetryMicros = 0; NoProbe = $false },
    [pscustomobject]@{ Name = 'no_probe'; Cleanup = ''; RetryMicros = 0; NoProbe = $true },
    [pscustomobject]@{ Name = 'file_retry_50'; Cleanup = $quitMarker; RetryMicros = 50000; NoProbe = $false },
    [pscustomobject]@{ Name = 'file_retry_100'; Cleanup = $quitMarker; RetryMicros = 100000; NoProbe = $false },
    [pscustomobject]@{ Name = 'file_retry_250'; Cleanup = $quitMarker; RetryMicros = 250000; NoProbe = $false }
)

$results = [System.Collections.Generic.List[object]]::new()
$env:REPORT_EXIT_STATUS = '1'
$env:NO_INTERACTION = '1'
$env:TEST_PHP_EXECUTABLE = $php
$env:PHPRC = $PhpDirectory

foreach ($variant in $variants) {
    Get-Process -Name iexplore -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $content = $original
    if ($variant.NoProbe) {
        $content = [regex]::Replace(
            $content,
            '(?s)--SKIPIF--\r?\n<\?php.*?\?>',
            "--SKIPIF--`n<?php`nif (PHP_INT_SIZE != 4) die('skip for 32bit platforms only');`n?>",
            1
        )
    } else {
        $parts = $content -split '--FILE--', 2
        $parts[0] = $parts[0].Replace($quitMarker, $variant.Cleanup)
        $content = $parts -join '--FILE--'
    }

    if ($variant.RetryMicros -gt 0) {
        $parts = $content -split '--FILE--', 2
        $needle = '$ie = new com(''InternetExplorer.Application'');'
        $retry = @"
`$deadline = microtime(true) + 5;
do {
    try {
        `$ie = new com('InternetExplorer.Application');
        break;
    } catch (com_exception `$ex) {
        if (microtime(true) >= `$deadline) {
            throw `$ex;
        }
        usleep($($variant.RetryMicros));
    }
} while (true);
"@
        $parts[1] = $parts[1].Replace($needle, $retry.TrimEnd())
        $content = $parts -join '--FILE--'
    }

    $testPath = Join-Path $variantDirectory "$($variant.Name).phpt"
    Set-Content -LiteralPath $testPath -Value $content -NoNewline -Encoding UTF8
    $variantLog = Join-Path $logDirectory "$($variant.Name).log"

    for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
        $before = @(Get-Process -Name iexplore -ErrorAction SilentlyContinue).Count
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $lines = & $php -n $runner -p $php -n -c $ini -q --show-diff --set-timeout 60 $testPath 2>&1
        $exitCode = $LASTEXITCODE
        $stopwatch.Stop()
        $text = $lines -join "`n"
        $after = @(Get-Process -Name iexplore -ErrorAction SilentlyContinue).Count

        $status = if ($text -match '(?m)^PASS ') {
            'PASS'
        } elseif ($text -match '(?m)^SKIP ') {
            'SKIP'
        } elseif ($text -match '(?m)^BORK ') {
            'BORK'
        } elseif ($text -match '(?m)^FAIL ') {
            'FAIL'
        } elseif ($exitCode -eq 0) {
            'UNKNOWN_OK'
        } else {
            'UNKNOWN_FAIL'
        }

        @(
            "===== iteration $iteration | status=$status | exit=$exitCode | elapsed_ms=$($stopwatch.ElapsedMilliseconds) | ie_before=$before | ie_after=$after ====="
            $text
            ''
        ) | Add-Content -LiteralPath $variantLog -Encoding UTF8

        $results.Add([pscustomobject]@{
            Variant = $variant.Name
            Iteration = $iteration
            Status = $status
            ExitCode = $exitCode
            ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
            IeProcessesBefore = $before
            IeProcessesAfter = $after
        })
    }
}

$csv = Join-Path $OutputDirectory 'phpt-results.csv'
$json = Join-Path $OutputDirectory 'phpt-results.json'
$summary = Join-Path $OutputDirectory 'summary.txt'
$results | Export-Csv -LiteralPath $csv -NoTypeInformation
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $json -Encoding UTF8

$grouped = $results |
    Group-Object Variant |
    ForEach-Object {
        $items = $_.Group
        [pscustomobject]@{
            Variant = $_.Name
            PASS = @($items | Where-Object Status -EQ 'PASS').Count
            SKIP = @($items | Where-Object Status -EQ 'SKIP').Count
            FAIL = @($items | Where-Object { $_.Status -in @('FAIL', 'BORK', 'UNKNOWN_FAIL') }).Count
            AverageMilliseconds = [math]::Round(($items | Measure-Object ElapsedMilliseconds -Average).Average, 1)
            MaximumMilliseconds = ($items | Measure-Object ElapsedMilliseconds -Maximum).Maximum
        }
    }

$grouped | Sort-Object Variant | Format-Table -AutoSize | Tee-Object -FilePath $summary
