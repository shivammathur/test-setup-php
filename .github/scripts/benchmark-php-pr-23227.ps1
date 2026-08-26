param(
    [Parameter(Mandatory = $true)]
    [string] $BaselinePhp,
    [Parameter(Mandatory = $true)]
    [string] $PrPhp,
    [Parameter(Mandatory = $true)]
    [ValidateSet('x64', 'x86')]
    [string] $Arch,
    [Parameter(Mandatory = $true)]
    [ValidateRange(3, 31)]
    [int] $Iterations,
    [Parameter(Mandatory = $true)]
    [string] $PhpSrcRoot,
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'

function Get-Median {
    param([double[]] $Values)

    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) {
        return [double]$sorted[$middle]
    }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Find-OpcachePath {
    param([string] $PhpExe)

    $phpDirectory = Split-Path -Parent $PhpExe
    $opcache = Get-ChildItem $phpDirectory -Filter php_opcache.dll -File -Recurse |
        Select-Object -First 1 -ExpandProperty FullName
    return $opcache
}

function Get-PhpArguments {
    param(
        [string] $PhpExe,
        [string] $Mode,
        [string] $Script
    )

    $arguments = @('-n')
    if ($Mode -eq 'jit-tracing') {
        $opcache = Find-OpcachePath -PhpExe $PhpExe
        if (![string]::IsNullOrWhiteSpace($opcache)) {
            $arguments += @('-d', "zend_extension=$opcache")
        }
        $arguments += @(
            '-d', 'opcache.enable_cli=1',
            '-d', 'opcache.jit_buffer_size=128M',
            '-d', 'opcache.jit=tracing'
        )
    }
    $arguments += $Script
    return $arguments
}

function Invoke-BenchmarkOnce {
    param(
        [string] $PhpExe,
        [string] $Mode,
        [string] $Script
    )

    $arguments = Get-PhpArguments -PhpExe $PhpExe -Mode $Mode -Script $Script
    $previousScanDirectory = $env:PHP_INI_SCAN_DIR
    try {
        $env:PHP_INI_SCAN_DIR = ''
        $output = & $PhpExe @arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        if ($null -eq $previousScanDirectory) {
            Remove-Item Env:PHP_INI_SCAN_DIR -ErrorAction SilentlyContinue
        } else {
            $env:PHP_INI_SCAN_DIR = $previousScanDirectory
        }
    }

    if ($exitCode -ne 0) {
        throw "Benchmark failed with $PhpExe ($Mode): $($output | Out-String)"
    }

    $outputText = $output | Out-String
    $match = [regex]::Match($outputText, '(?m)^Total\s+([0-9.,]+)\s*$')
    if (-not $match.Success) {
        throw "Could not parse Total from $PhpExe ($Mode): $outputText"
    }

    return [double]::Parse(
        $match.Groups[1].Value.Replace(',', ''),
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Invoke-InterleavedSuite {
    param(
        [string] $Name,
        [string] $Mode,
        [string] $Script
    )

    Write-Host "Running $Name ($Mode)"
    for ($warmup = 0; $warmup -lt 2; $warmup++) {
        [void](Invoke-BenchmarkOnce -PhpExe $BaselinePhp -Mode $Mode -Script $Script)
        [void](Invoke-BenchmarkOnce -PhpExe $PrPhp -Mode $Mode -Script $Script)
    }

    $baselineSamples = [Collections.Generic.List[double]]::new()
    $prSamples = [Collections.Generic.List[double]]::new()

    for ($iteration = 0; $iteration -lt $Iterations; $iteration++) {
        if (($iteration % 2) -eq 0) {
            $baselineSamples.Add((Invoke-BenchmarkOnce -PhpExe $BaselinePhp -Mode $Mode -Script $Script))
            $prSamples.Add((Invoke-BenchmarkOnce -PhpExe $PrPhp -Mode $Mode -Script $Script))
        } else {
            $prSamples.Add((Invoke-BenchmarkOnce -PhpExe $PrPhp -Mode $Mode -Script $Script))
            $baselineSamples.Add((Invoke-BenchmarkOnce -PhpExe $BaselinePhp -Mode $Mode -Script $Script))
        }
    }

    $baselineMedian = Get-Median -Values $baselineSamples.ToArray()
    $prMedian = Get-Median -Values $prSamples.ToArray()
    $improvement = (($baselineMedian - $prMedian) / $baselineMedian) * 100

    return [pscustomobject]@{
        arch = $Arch
        benchmark = $Name
        mode = $Mode
        iterations = $Iterations
        baseline_median_s = [Math]::Round($baselineMedian, 6)
        pr_median_s = [Math]::Round($prMedian, 6)
        improvement_percent = [Math]::Round($improvement, 3)
        baseline_samples_s = $baselineSamples.ToArray()
        pr_samples_s = $prSamples.ToArray()
    }
}

$benchScript = Join-Path $PhpSrcRoot 'Zend\bench.php'
$microBenchScript = Join-Path $PhpSrcRoot 'Zend\micro_bench.php'
$compileBenchScript = Join-Path $PSScriptRoot '..\benchmarks\tls_compile.php'
foreach ($script in @($benchScript, $microBenchScript, $compileBenchScript)) {
    if (-not (Test-Path $script)) {
        throw "Missing benchmark script: $script"
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$suites = @(
    @{ Name = 'Zend bench'; Mode = 'interpreter'; Script = $benchScript },
    @{ Name = 'Zend micro_bench'; Mode = 'interpreter'; Script = $microBenchScript },
    @{ Name = 'compile/eval'; Mode = 'interpreter'; Script = $compileBenchScript },
    @{ Name = 'Zend bench'; Mode = 'jit-tracing'; Script = $benchScript },
    @{ Name = 'Zend micro_bench'; Mode = 'jit-tracing'; Script = $microBenchScript }
)

$results = foreach ($suite in $suites) {
    Invoke-InterleavedSuite -Name $suite.Name -Mode $suite.Mode -Script $suite.Script
}

$jsonPath = Join-Path $OutputDirectory 'results.json'
$csvPath = Join-Path $OutputDirectory 'results.csv'
$results | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath
$results |
    Select-Object arch, benchmark, mode, iterations, baseline_median_s, pr_median_s, improvement_percent |
    Export-Csv -Path $csvPath -NoTypeInformation

$summary = @(
    "## PHP PR 23227 ZTS benchmark ($Arch)",
    '',
    'Positive improvement means the PR is faster. Medians use interleaved runs after two warmups.',
    '',
    '| Benchmark | Mode | Merge base (s) | PR (s) | Improvement |',
    '|---|---:|---:|---:|---:|'
)
foreach ($result in $results) {
    $summary += '| {0} | {1} | {2:N6} | {3:N6} | {4:+0.000;-0.000;0.000}% |' -f `
        $result.benchmark, $result.mode, $result.baseline_median_s, $result.pr_median_s, $result.improvement_percent
}

$summaryPath = Join-Path $OutputDirectory 'summary.md'
$summary | Set-Content -Path $summaryPath
$summary | Add-Content -Path $env:GITHUB_STEP_SUMMARY
$summary | ForEach-Object { Write-Host $_ }
