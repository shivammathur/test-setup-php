$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'run-comparison.ps1'
$source = Get-Content $scriptPath -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
$mocks = @{
    'Invoke-PhpText' = 'function Invoke-PhpText { param($Php, $Arguments); if (@($Arguments | Where-Object { $_ -like "*check-jit.php" }).Count) { return ''{"generated_bytes":1024,"checksum":"same"}'' }; return "test-runtime" }'
    'Get-PhpArguments' = 'function Get-PhpArguments { param($Php, $Benchmark); return @("-n") }'
    'Invoke-BenchmarkSample' = @'
function Invoke-BenchmarkSample {
    param($Label, $Php, $Benchmark, $Sample)
    [pscustomobject]@{label=$Label; benchmark=$Benchmark.Name; sample=$Sample; elapsed_ms=(@{nojit=100;previous=105;accumulated=107;'gl-nojit'=99;'gl-pr'=98;'gl-accumulated'=95}[$Label] + $Sample / 1000); checksum='same'}
}
'@
}
$definitions = $ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true)
foreach ($definition in @($definitions | Sort-Object { $_.Extent.StartOffset } -Descending)) {
    if ($mocks.ContainsKey($definition.Name)) {
        $source = $source.Remove($definition.Extent.StartOffset, $definition.Extent.EndOffset - $definition.Extent.StartOffset).Insert($definition.Extent.StartOffset, $mocks[$definition.Name])
    }
}
$root = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
$source = $source.Replace('$PSScriptRoot', "'$($PSScriptRoot.Replace("'", "''"))'")
New-Item -ItemType Directory $root | Out-Null
foreach ($jit in @($false, $true)) {
    $paths = @{nojit='nojit';previous='previous';accumulated='accumulated';'gl-nojit'='gl-nojit';'gl-pr'='gl-pr';'gl-accumulated'='gl-accumulated'}
    $pathsFile = Join-Path $root "paths-$jit.json"
    $paths | ConvertTo-Json | Set-Content $pathsFile
    $output = Join-Path $root "results-$jit"
    & ([scriptblock]::Create($source)) -RuntimePaths $pathsFile -OutputDirectory $output -Samples 24 -EnableJit $jit | Out-Null
    $result = Get-Content (Join-Path $output 'results.json') -Raw | ConvertFrom-Json
    $benchmarks = if ($jit) { 7 } else { 5 }
    if ($result.samples.Count -ne (24 * 6 * $benchmarks)) { throw 'Sample count mismatch' }
    if ($result.summary.Count -ne 10 * $benchmarks) { throw 'Missing comparisons' }
    if (@($result.summary | Where-Object { $_.candidate -like 'gl-*' -and $_.paired_delta_percent -ge 0 }).Count) { throw 'Incorrect ratio calculation' }
    $orders = @($result.samples | Where-Object benchmark -eq 'vm' | Group-Object sample | ForEach-Object { $_.Group.label -join ',' } | Sort-Object -Unique)
    if ($orders.Count -ne 12) { throw 'Execution order is not balanced' }
    foreach ($label in $paths.Keys) {
        for ($position = 0; $position -lt 6; $position++) {
            if (@($orders | Where-Object { $_.Split(',')[$position] -eq $label }).Count -ne 2) { throw 'Position imbalance' }
        }
        foreach ($other in $paths.Keys) {
            if ($other -eq $label) { continue }
            if (@($orders | Where-Object { $o = $_.Split(','); [array]::IndexOf($o, $label) -lt [array]::IndexOf($o, $other) }).Count -ne 6) { throw 'Pair order imbalance' }
        }
    }
}
Write-Host 'Six-way benchmark harness passed: checksums, comparisons, balanced positions and pair order.'
