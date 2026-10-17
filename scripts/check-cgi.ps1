param([string] $RuntimePaths, [string] $OutputDirectory, [int] $Samples = 200)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$paths = Get-Content $RuntimePaths -Raw | ConvertFrom-Json -AsHashtable
$results = [Collections.Generic.List[object]]::new()
# Mirror the failing CGI test with explicit stderr/exit-code collection. Keep the
# CLI alive with OPcache while its CGI children attach, as in the PHPT harness.
$script = @'
<?php
foreach (['REDIRECT_STATUS','QUERY_STRING','PATH_TRANSLATED','SCRIPT_FILENAME','SERVER_SOFTWARE','SERVER_NAME','GATEWAY_INTERFACE','REQUEST_METHOD'] as $key) putenv($key);
$cgi = dirname(PHP_BINARY) . '/php-cgi.exe';
$results = [];
for ($i = 0; $i < (int)$argv[1]; $i++) {
    $pipes = [];
    $process = proc_open([$cgi, '-n', '-f', 'some.php', '-f', 'some.php'], [0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']], $pipes);
    fclose($pipes[0]);
    $output = stream_get_contents($pipes[1]); fclose($pipes[1]);
    $error = stream_get_contents($pipes[2]); fclose($pipes[2]);
    $exit = proc_close($process);
    $results[] = ['sample'=>$i, 'stdout'=>$output, 'stderr'=>$error, 'exit'=>$exit,
        'pass'=>str_replace("\r\n", "\n", $output) === "No input file specified.\n" && $error === ''];
}
echo json_encode($results, JSON_THROW_ON_ERROR);
'@
$scriptFile = Join-Path (Resolve-Path $OutputDirectory).Path 'repeated-cgi.php'
Set-Content $scriptFile $script
foreach ($label in $paths.Keys) {
    foreach ($opcache in @(0, 1)) {
        $start = [Diagnostics.ProcessStartInfo]::new($paths[$label])
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-n', '-d', "opcache.enable_cli=$opcache", '-d', 'opcache.jit=disable', $scriptFile, "$Samples")) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(300000)) { $process.Kill($true); throw "$label CGI check timed out" }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        Set-Content (Join-Path $OutputDirectory "$label-$opcache.json") $stdout
        Set-Content (Join-Path $OutputDirectory "$label-$opcache.stderr") $stderr
        if ($process.ExitCode -ne 0 -or $stderr.Trim()) { throw "$label parent failed: $stderr" }
        $checks = @($stdout | ConvertFrom-Json)
        if ($checks.Count -ne $Samples) { throw "$label missing samples" }
        $failures = @($checks | Where-Object { -not $_.pass })
        $results.Add([pscustomobject]@{label=$label;opcache=$opcache;samples=$Samples;failures=$failures.Count})
        Write-Host "$label opcache=$opcache : $($failures.Count)/$Samples CGI failures"
    }
}
$results | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'summary.json')
if (@($results | Where-Object failures -gt 0).Count) { throw 'CGI startup failures reproduced; inspect captured exit codes and stderr' }
