param(
    [Parameter(Mandatory = $true)]
    [string] $RuntimePaths,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,

    [int] $Samples = 24,
    [bool] $EnableJit = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest


New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$script:builtInOpcache = @{}

function Invoke-PhpText {
    param(
        [string] $Php,
        [string[]] $Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Php
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) {
        $process.Kill($true)
        throw "'$Php' exceeded the five-minute timeout"
    }
    $standardOutput = $outputTask.GetAwaiter().GetResult()
    $standardError = $errorTask.GetAwaiter().GetResult()

    if ($process.ExitCode -ne 0) {
        $diagnosticOutput = @($standardOutput, $standardError) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $serializedArguments = ConvertTo-Json -Compress -InputObject @($Arguments)
        throw "'$Php' failed with exit code $($process.ExitCode) using arguments $serializedArguments`: $($diagnosticOutput -join [Environment]::NewLine)"
    }

    if (-not [string]::IsNullOrWhiteSpace($standardError)) {
        throw "'$Php' wrote to stderr: $($standardError.Trim())"
    }

    return $standardOutput.Trim()
}

function Get-Median {
    param([double[]] $Values)

    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)

    if (($sorted.Count % 2) -eq 1) {
        return [double] $sorted[$middle]
    }

    return ([double] $sorted[$middle - 1] + [double] $sorted[$middle]) / 2
}

function Get-PhpArguments {
    param(
        [string] $Php,
        [hashtable] $Benchmark
    )

    $arguments = @('-n', '-d', 'opcache.enable_cli=0')
    $phpRoot = Split-Path -Parent $Php
    $extensionDirectory = Join-Path $phpRoot 'ext'

    if ($Benchmark.Opcache) {
        $opcache = Join-Path $extensionDirectory 'php_opcache.dll'
        if (Test-Path -LiteralPath $opcache -PathType Leaf) {
            $arguments += @('-d', "zend_extension=$opcache")
        } else {
            if (-not $script:builtInOpcache.ContainsKey($Php)) {
                $loaded = Invoke-PhpText -Php $Php -Arguments @(
                    '-n',
                    '-r',
                    'echo extension_loaded("Zend OPcache") ? "1" : "0";'
                )
                $script:builtInOpcache[$Php] = ($loaded -eq '1')
            }

            if (-not $script:builtInOpcache[$Php]) {
                throw "OPcache is neither built in nor available as a shared extension: $opcache"
            }
        }

        $arguments += @(
            '-d', 'opcache.enable_cli=1',
            '-d', ('opcache.jit=' + $(if ($Benchmark.Jit) { 'tracing' } else { 'disable' })),
            '-d', ('opcache.jit_buffer_size=' + $(if ($Benchmark.Jit) { '64M' } else { '0' }))
        )
    }

    if ($Benchmark.PdoSqlite) {
        $pdoSqlite = Join-Path $extensionDirectory 'php_pdo_sqlite.dll'
        if (-not (Test-Path -LiteralPath $pdoSqlite -PathType Leaf)) {
            throw "PDO SQLite extension not found: $pdoSqlite"
        }

        $arguments += @(
            '-d', "extension_dir=$extensionDirectory",
            '-d', 'extension=php_pdo_sqlite.dll'
        )
    }

    return $arguments
}

function Invoke-BenchmarkSample {
    param(
        [string] $Label,
        [string] $Php,
        [hashtable] $Benchmark,
        [int] $Sample
    )

    $arguments = @(Get-PhpArguments -Php $Php -Benchmark $Benchmark)
    $arguments += @('-f', $Benchmark.Script)
    $arguments += @($Benchmark.Arguments)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $checksum = Invoke-PhpText -Php $Php -Arguments $arguments
    $stopwatch.Stop()

    return [pscustomobject]@{
        label = $Label
        benchmark = $Benchmark.Name
        sample = $Sample
        elapsed_ms = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 4)
        checksum = $checksum
    }
}

$paths = Get-Content $RuntimePaths -Raw | ConvertFrom-Json -AsHashtable
$labels = @('nojit', 'previous', 'accumulated', 'gl-nojit', 'gl-pr', 'gl-accumulated')
if (@($labels | Where-Object { -not $paths.ContainsKey($_) }).Count) { throw 'Missing comparison runtimes' }
if ($Samples -lt 12 -or ($Samples % 12) -ne 0) { throw 'Samples must be a positive multiple of twelve for balanced order.' }
$phpVersion = $null
$runtimeInfo = [ordered]@{}
foreach ($label in $labels) {
    $version = Invoke-PhpText -Php $paths[$label] -Arguments @('-n', '-r', 'echo PHP_VERSION;')
    if ($phpVersion -and $version -ne $phpVersion) { throw 'PHP version mismatch' }
    $phpVersion = $version
    $runtimeInfo[$label] = Invoke-PhpText -Php $paths[$label] -Arguments @('-n', '-v')
}

$benchmarks = @(
    @{
        Name = 'vm'
        Script = Join-Path $PSScriptRoot '..\benchmarks\vm.php'
        Arguments = @()
        Opcache = $false
        Jit = $false
        PdoSqlite = $false
    },
    @{
        Name = 'vm-opcache'
        Script = Join-Path $PSScriptRoot '..\benchmarks\vm.php'
        Arguments = @()
        Opcache = $true
        Jit = $false
        PdoSqlite = $false
    },
    @{
        Name = 'mixed'
        Script = Join-Path $PSScriptRoot '..\benchmarks\mixed.php'
        Arguments = @()
        Opcache = $false
        Jit = $false
        PdoSqlite = $false
    },
    @{
        Name = 'mixed-opcache'
        Script = Join-Path $PSScriptRoot '..\benchmarks\mixed.php'
        Arguments = @()
        Opcache = $true
        Jit = $false
        PdoSqlite = $false
    },
    @{
        Name = 'pdo-sqlite'
        Script = Join-Path $PSScriptRoot '..\benchmarks\pdo_sqlite.php'
        Arguments = @()
        Opcache = $false
        Jit = $false
        PdoSqlite = $true
    },
    @{
        Name = 'vm-jit'
        Script = Join-Path $PSScriptRoot '..\benchmarks\vm.php'
        Arguments = @()
        Opcache = $true
        Jit = $true
        PdoSqlite = $false
    },
    @{
        Name = 'mixed-jit'
        Script = Join-Path $PSScriptRoot '..\benchmarks\mixed.php'
        Arguments = @()
        Opcache = $true
        Jit = $true
        PdoSqlite = $false
    }
)

if ($EnableJit) {
    $jitVerification = [ordered]@{}
    foreach ($label in $labels) {
        $php = $paths[$label]
        $arguments = @(Get-PhpArguments -Php $php -Benchmark $benchmarks[-1])
        $arguments += @('-r', '$s = opcache_get_status(false); if (empty($s["jit"]["on"]) || $s["jit"]["kind"] !== 5) { fwrite(STDERR, "Tracing JIT is not active"); exit(1); } echo json_encode($s["jit"]);')
        Write-Host "Verified $label tracing JIT: $(Invoke-PhpText -Php $php -Arguments $arguments)"
        $jitVerification[$label] = [ordered]@{}
        foreach ($benchmark in @($benchmarks | Where-Object Jit)) {
            $arguments = @(Get-PhpArguments -Php $php -Benchmark $benchmark)
            $arguments += @('-f', (Join-Path $PSScriptRoot 'check-jit.php'), $benchmark.Script)
            $probe = Invoke-PhpText -Php $php -Arguments $arguments
            $jitVerification[$label][$benchmark.Name] = $probe | ConvertFrom-Json
            Write-Host "Verified $label $($benchmark.Name) emitted JIT code: $probe"
        }
    }
    $jitVerification | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutputDirectory 'jit-verification.json')
} else {
    $benchmarks = @($benchmarks | Where-Object { -not $_.Jit })
}

foreach ($benchmark in $benchmarks) {
    $warmups = @(foreach ($label in $labels) {
        Invoke-BenchmarkSample -Label $label -Php $paths[$label] -Benchmark $benchmark -Sample 0
    })
    if (@($warmups.checksum | Select-Object -Unique).Count -ne 1) {
        throw "Checksum mismatch during '$($benchmark.Name)' warmup."
    }
}

$samplesOutput = [System.Collections.Generic.List[object]]::new()
$orders = @()
for ($offset = 0; $offset -lt $labels.Count; $offset++) {
    $rotated = @(0..($labels.Count - 1) | ForEach-Object { $labels[($_ + $offset) % $labels.Count] })
    $orders += $rotated -join ','
    [array]::Reverse($rotated)
    $orders += $rotated -join ','
}

for ($sample = 1; $sample -le $Samples; $sample++) {
    foreach ($benchmark in $benchmarks) {
        foreach ($label in $orders[($sample - 1) % $orders.Count].Split(',')) {
            $php = $paths[$label]
            $result = Invoke-BenchmarkSample -Label $label -Php $php -Benchmark $benchmark -Sample $sample
            $samplesOutput.Add($result)
        }

        $pair = @($samplesOutput | Where-Object {
            ($_.benchmark -eq $benchmark.Name) -and ($_.sample -eq $sample)
        })

        if (@($pair.checksum | Select-Object -Unique).Count -ne 1) {
            throw "Checksum mismatch during '$($benchmark.Name)' sample $sample."
        }
    }
    $samplesOutput | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'samples.json')
    Write-Host "Completed sample $sample/$Samples"
}

$summary = [System.Collections.Generic.List[object]]::new()
$comparisons = @(
    @{ reference='nojit'; candidate='gl-nojit' },
    @{ reference='gl-nojit'; candidate='gl-pr' },
    @{ reference='gl-nojit'; candidate='gl-accumulated' },
    @{ reference='previous'; candidate='gl-pr' },
    @{ reference='accumulated'; candidate='gl-accumulated' },
    @{ reference='gl-pr'; candidate='gl-accumulated' },
    @{ reference='nojit'; candidate='previous' },
    @{ reference='nojit'; candidate='accumulated' },
    @{ reference='nojit'; candidate='gl-pr' },
    @{ reference='nojit'; candidate='gl-accumulated' }
)

foreach ($benchmark in $benchmarks) {
  foreach ($comparison in $comparisons) {
    $baselineSamples = @($samplesOutput | Where-Object {
        ($_.benchmark -eq $benchmark.Name) -and ($_.label -eq $comparison.reference)
    } | Sort-Object sample)
    $candidateSamples = @($samplesOutput | Where-Object {
        ($_.benchmark -eq $benchmark.Name) -and ($_.label -eq $comparison.candidate)
    } | Sort-Object sample)

    $baselineTimes = [double[]] @($baselineSamples.elapsed_ms)
    $candidateTimes = [double[]] @($candidateSamples.elapsed_ms)
    $pairedRatios = [System.Collections.Generic.List[double]]::new()

    for ($index = 0; $index -lt $baselineSamples.Count; $index++) {
        $pairedRatios.Add(
            [double] $candidateSamples[$index].elapsed_ms / [double] $baselineSamples[$index].elapsed_ms
        )
    }

    $baselineMedian = Get-Median -Values $baselineTimes
    $candidateMedian = Get-Median -Values $candidateTimes
    $ratioMedian = Get-Median -Values ([double[]] $pairedRatios)

    $summary.Add([pscustomobject]@{
        benchmark = $benchmark.Name
        reference = $comparison.reference
        candidate = $comparison.candidate
        baseline_median_ms = [Math]::Round($baselineMedian, 3)
        candidate_median_ms = [Math]::Round($candidateMedian, 3)
        paired_delta_percent = [Math]::Round(($ratioMedian - 1) * 100, 2)
        speedup = [Math]::Round(1 / $ratioMedian, 4)
    })
  }
}

$resultDocument = [ordered]@{
    php_version = $phpVersion
    runtimes = $paths
    runtime_info = $runtimeInfo
    sample_count = $Samples
    summary = $summary
    samples = $samplesOutput
}

$resultPath = Join-Path $OutputDirectory 'results.json'
$resultDocument | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8

$markdown = [System.Collections.Generic.List[string]]::new()
$markdown.Add("# PHP $phpVersion runtime comparison")
$markdown.Add('')
$markdown.Add('Labels: nojit = previous no-JIT-training build; previous = JIT PR without compiler fix; accumulated = accumulated profiles without compiler fix; gl-nojit = compiler fix + SDK master without JIT training; gl-pr = compiler fix + JIT PR; gl-accumulated = compiler fix + accumulated profiles. Runtime JIT settings are identical within each benchmark.')
$markdown.Add('')
$provenancePath = Join-Path $OutputDirectory 'provenance.json'
if (Test-Path $provenancePath) {
    $provenance = Get-Content $provenancePath -Raw | ConvertFrom-Json
    $markdown.Add($provenance.source_comparison)
    if (-not $provenance.valid_training) { $markdown.Add("WARNING: $($provenance.caveat)"); $markdown.Add('') }
}
$markdown.Add('Delta is the median of paired candidate/reference time ratios; negative is faster. Execution order is balanced across samples.')
$markdown.Add('')
$markdown.Add('| Benchmark | Reference | Candidate | Reference median (ms) | Candidate median (ms) | Delta | Speedup |')
$markdown.Add('|---|---|---|---:|---:|---:|---:|')

foreach ($row in $summary) {
    $markdown.Add(
        "| $($row.benchmark) | $($row.reference) | $($row.candidate) | $($row.baseline_median_ms) | $($row.candidate_median_ms) | $($row.paired_delta_percent)% | $($row.speedup)x |"
    )
}

$summaryPath = Join-Path $OutputDirectory 'summary.md'
$markdown | Set-Content -LiteralPath $summaryPath -Encoding utf8
$markdown -join [Environment]::NewLine
