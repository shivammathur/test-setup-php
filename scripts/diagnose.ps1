param(
    [string[]] $Modes = @('vm','no-sort','sort','arithmetic','mixed','empty'),
    [string[]] $JitModes = @('disable','tracing'),
    [switch] $SkipTrace
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$paths = Get-Content results/runtime-paths.json -Raw | ConvertFrom-Json -AsHashtable
$orders = @('nojit,previous,fixed', 'fixed,previous,nojit', 'previous,nojit,fixed',
            'fixed,nojit,previous', 'nojit,fixed,previous', 'previous,fixed,nojit')
$rows = [Collections.Generic.List[object]]::new()

function Invoke-Diagnostic {
    param($Label, $Mode, $Jit, $Sample, [bool] $Trace = $false)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $paths[$Label]
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $cli = if ($Mode.EndsWith('-raw')) { '0' } else { '1' }
    $arguments = @('-n', '-d', "opcache.enable_cli=$cli", '-d', "opcache.jit=$Jit", '-d',
        ('opcache.jit_buffer_size=' + $(if ($Jit -eq 'tracing') { '64M' } else { '0' })))
    if ($Trace) { $arguments += @('-d', 'opcache.jit_debug=1') }
    $arguments += @('-f', (Join-Path $PSScriptRoot '../benchmarks/diagnose.php'), $Mode)
    foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($info)
    # Apply the same affinity to every variant. Inner timing excludes launch overhead.
    if (-not $process.HasExited) { $process.ProcessorAffinity = [IntPtr]1 }
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { $process.Kill($true); throw 'Timeout' }
    $clock.Stop()
    $stdout = $out.GetAwaiter().GetResult()
    $stderr = $err.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "$Label $Mode failed: $stderr" }
    if ($Trace) {
        $stderr | Set-Content "results/trace-$Label-$Mode.txt"
    } elseif ($stderr.Trim()) { throw "$Label $Mode wrote stderr: $stderr" }
    $result = $stdout | ConvertFrom-Json
    if ($Jit -eq 'tracing' -and (-not $result.jit.on -or $result.jit.kind -ne 5)) { throw 'JIT not active' }
    $row = [ordered]@{label=$Label; mode=$Mode; jit=$Jit; sample=$Sample; checksum=$result.checksum;
        inner_ms=$result.inner_ms; wall_ms=$clock.Elapsed.TotalMilliseconds; cpu_ms=$process.TotalProcessorTime.TotalMilliseconds;
        jit_status=$result.jit}
    $process.Dispose()
    return [pscustomobject]$row
}

foreach ($mode in $Modes) {
    foreach ($jit in $JitModes) {
        $expected = $null
        for ($sample=0; $sample -le 12; $sample++) {
            foreach ($label in $orders[($sample % 6)].Split(',')) {
                $row = Invoke-Diagnostic $label $mode $jit $sample
                if ($null -eq $expected) { $expected=$row.checksum }
                if ($row.checksum -ne $expected) { throw 'Checksum differs between variants' }
                if ($sample -gt 0) { $rows.Add($row) }
            }
        }
        $rows | ConvertTo-Json -Depth 8 | Set-Content results/diagnostic-samples.json
        Write-Host "Completed $mode $jit"
    }
}
if (-not $SkipTrace) { foreach ($label in @('nojit','previous','fixed')) {
    foreach ($mode in @('vm','no-sort','sort','arithmetic')) {
        Invoke-Diagnostic $label $mode tracing 0 $true | ConvertTo-Json -Depth 8 | Set-Content "results/trace-status-$label-$mode.json"
    }
} }
