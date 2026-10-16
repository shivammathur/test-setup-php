param([string] $BaselinePhp, [string] $CandidatePhp, [string] $OutputDirectory)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
foreach ($label in @('baseline', 'candidate')) {
    $php = if ($label -eq 'baseline') { $BaselinePhp } else { $CandidatePhp }
    foreach ($mode in @('function', 'tracing')) {
        $ini = Join-Path (Resolve-Path $OutputDirectory).Path "$label-$mode.ini"
        @(
            'opcache.enable=1'
            'opcache.enable_cli=1'
            'opcache.protect_memory=1'
            "opcache.jit=$mode"
            'opcache.jit_buffer_size=64M'
            'opcache.jit_hot_func=1'
            'opcache.jit_hot_loop=1'
            "opcache.cache_id=jit-pgo-$label-$mode-$env:GITHUB_RUN_ID"
        ) | Set-Content $ini
        $start = [Diagnostics.ProcessStartInfo]::new($php)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-n', '-c', $ini, (Join-Path $PSScriptRoot 'jit-multiprocess.php'))) {
            $start.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::Start($start)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(300000)) {
            $process.Kill($true)
            throw "$label $mode multiprocess check timed out"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        @($stdout, $stderr) | Set-Content (Join-Path $OutputDirectory "$label-$mode.log")
        if ($process.ExitCode -ne 0 -or $stderr.Trim()) { throw "$label $mode failed: $stdout $stderr" }
        Write-Host "$label $mode : $stdout"
    }
}
