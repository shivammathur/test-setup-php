$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'run-comparison.ps1'
$source = Get-Content $scriptPath -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
$mocks = @{
    'Invoke-PhpText' = 'function Invoke-PhpText { param($Php, $Arguments); return "test-runtime" }'
    'Get-PhpArguments' = 'function Get-PhpArguments { param($Php, $Benchmark); return @("-n") }'
    'Invoke-BenchmarkSample' = @'
function Invoke-BenchmarkSample {
    param($Label, $Php, $Benchmark, $Sample)
    [pscustomobject]@{label=$Label; benchmark=$Benchmark.Name; sample=$Sample; elapsed_ms=(@{nojit=100;previous=105;fixed=99}[$Label] + $Sample / 1000); checksum='same'}
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
foreach ($count in @(2, 3)) {
    $paths = @{previous='previous';fixed='fixed'}
    if ($count -eq 3) { $paths.nojit='nojit' }
    $pathsFile = Join-Path $root "paths-$count.json"
    $paths | ConvertTo-Json | Set-Content $pathsFile
    $output = Join-Path $root "results-$count"
    & ([scriptblock]::Create($source)) -RuntimePaths $pathsFile -OutputDirectory $output -Samples 6 -EnableJit ($count -eq 3) | Out-Null
    $result = Get-Content (Join-Path $output 'results.json') -Raw | ConvertFrom-Json
    $benchmarks = if ($count -eq 3) { 7 } else { 5 }
    if ($result.samples.Count -ne (6 * $count * $benchmarks)) { throw 'Sample count mismatch' }
    if (@($result.summary | Where-Object { $_.candidate -eq 'fixed' -and $_.paired_delta_percent -ge 0 }).Count) { throw 'Incorrect ratio calculation' }
    $orders = @($result.samples | Where-Object benchmark -eq 'vm' | Group-Object sample | ForEach-Object { $_.Group.label -join ',' } | Sort-Object -Unique)
    if ($orders.Count -ne $(if ($count -eq 3) { 6 } else { 2 })) { throw 'Execution order is not balanced' }
}
Write-Host 'Two-way and three-way benchmark harness tests passed.'
