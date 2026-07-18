param(
    [Parameter(Mandatory = $true)]
    [string] $BaselinePhp,

    [Parameter(Mandatory = $true)]
    [string] $CandidatePhp,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,

    [int] $Samples = 9
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (($Samples -lt 5) -or (($Samples % 2) -eq 0)) {
    throw 'Samples must be an odd integer greater than or equal to 5.'
}

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
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

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

    $arguments = @('-n')
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
            '-d', 'opcache.jit=disable'
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

$baselineVersion = Invoke-PhpText -Php $BaselinePhp -Arguments @('-n', '-r', 'echo PHP_VERSION;')
$candidateVersion = Invoke-PhpText -Php $CandidatePhp -Arguments @('-n', '-r', 'echo PHP_VERSION;')
$baselineInfo = Invoke-PhpText -Php $BaselinePhp -Arguments @('-n', '-v')
$candidateInfo = Invoke-PhpText -Php $CandidatePhp -Arguments @('-n', '-v')

if ($baselineVersion -ne $candidateVersion) {
    throw "PHP version mismatch: baseline=$baselineVersion candidate=$candidateVersion"
}

$benchmarks = @(
    @{
        Name = 'vm'
        Script = Join-Path $PSScriptRoot '..\benchmarks\vm.php'
        Arguments = @()
        Opcache = $false
        PdoSqlite = $false
    },
    @{
        Name = 'vm-opcache'
        Script = Join-Path $PSScriptRoot '..\benchmarks\vm.php'
        Arguments = @()
        Opcache = $true
        PdoSqlite = $false
    },
    @{
        Name = 'mixed'
        Script = Join-Path $PSScriptRoot '..\benchmarks\mixed.php'
        Arguments = @()
        Opcache = $false
        PdoSqlite = $false
    },
    @{
        Name = 'mixed-opcache'
        Script = Join-Path $PSScriptRoot '..\benchmarks\mixed.php'
        Arguments = @()
        Opcache = $true
        PdoSqlite = $false
    },
    @{
        Name = 'pdo-sqlite'
        Script = Join-Path $PSScriptRoot '..\benchmarks\pdo_sqlite.php'
        Arguments = @()
        Opcache = $false
        PdoSqlite = $true
    }
)

foreach ($benchmark in $benchmarks) {
    $baselineWarmup = Invoke-BenchmarkSample -Label baseline -Php $BaselinePhp -Benchmark $benchmark -Sample 0
    $candidateWarmup = Invoke-BenchmarkSample -Label candidate -Php $CandidatePhp -Benchmark $benchmark -Sample 0

    if ($baselineWarmup.checksum -ne $candidateWarmup.checksum) {
        throw "Checksum mismatch during '$($benchmark.Name)' warmup."
    }
}

$samplesOutput = [System.Collections.Generic.List[object]]::new()

for ($sample = 1; $sample -le $Samples; $sample++) {
    foreach ($benchmark in $benchmarks) {
        $firstLabel = if (($sample % 2) -eq 1) { 'baseline' } else { 'candidate' }
        $secondLabel = if ($firstLabel -eq 'baseline') { 'candidate' } else { 'baseline' }

        foreach ($label in @($firstLabel, $secondLabel)) {
            $php = if ($label -eq 'baseline') { $BaselinePhp } else { $CandidatePhp }
            $result = Invoke-BenchmarkSample -Label $label -Php $php -Benchmark $benchmark -Sample $sample
            $samplesOutput.Add($result)
        }

        $pair = @($samplesOutput | Where-Object {
            ($_.benchmark -eq $benchmark.Name) -and ($_.sample -eq $sample)
        })

        if ($pair[0].checksum -ne $pair[1].checksum) {
            throw "Checksum mismatch during '$($benchmark.Name)' sample $sample."
        }
    }
}

$summary = [System.Collections.Generic.List[object]]::new()

foreach ($benchmark in $benchmarks) {
    $baselineSamples = @($samplesOutput | Where-Object {
        ($_.benchmark -eq $benchmark.Name) -and ($_.label -eq 'baseline')
    } | Sort-Object sample)
    $candidateSamples = @($samplesOutput | Where-Object {
        ($_.benchmark -eq $benchmark.Name) -and ($_.label -eq 'candidate')
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
        baseline_median_ms = [Math]::Round($baselineMedian, 3)
        candidate_median_ms = [Math]::Round($candidateMedian, 3)
        paired_delta_percent = [Math]::Round(($ratioMedian - 1) * 100, 2)
        speedup = [Math]::Round(1 / $ratioMedian, 4)
    })
}

$resultDocument = [ordered]@{
    php_version = $baselineVersion
    baseline_php = $BaselinePhp
    candidate_php = $CandidatePhp
    baseline_info = $baselineInfo
    candidate_info = $candidateInfo
    sample_count = $Samples
    summary = $summary
    samples = $samplesOutput
}

$resultPath = Join-Path $OutputDirectory 'results.json'
$resultDocument | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8

$markdown = [System.Collections.Generic.List[string]]::new()
$markdown.Add("# PHP $baselineVersion runtime comparison")
$markdown.Add('')
$markdown.Add("Candidate delta is based on the median of paired candidate/baseline sample ratios; negative is faster.")
$markdown.Add('')
$markdown.Add('| Benchmark | Baseline median (ms) | Candidate median (ms) | Candidate delta | Speedup |')
$markdown.Add('|---|---:|---:|---:|---:|')

foreach ($row in $summary) {
    $markdown.Add(
        "| $($row.benchmark) | $($row.baseline_median_ms) | $($row.candidate_median_ms) | $($row.paired_delta_percent)% | $($row.speedup)x |"
    )
}

$summaryPath = Join-Path $OutputDirectory 'summary.md'
$markdown | Set-Content -LiteralPath $summaryPath -Encoding utf8
$markdown -join [Environment]::NewLine
