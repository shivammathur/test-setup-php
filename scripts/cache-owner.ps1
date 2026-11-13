function Start-CacheOwner {
    param([Parameter(Mandatory)][string]$PhpRoot, [Parameter(Mandatory)][string]$Report, [int]$Children=0)
    $reservation=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $reservation.Start();$port=$reservation.LocalEndpoint.Port;$reservation.Stop()
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $PhpRoot 'php-cgi.exe'))
    $info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach ($argument in @('-c',(Join-Path $PhpRoot 'php.ini'),'-b',"127.0.0.1:$port")) { $info.ArgumentList.Add($argument) }
    $info.Environment['PHP_FCGI_MAX_REQUESTS']='0'
    if ($Children) { $info.Environment['PHP_FCGI_CHILDREN']=[string]$Children } else { $null=$info.Environment.Remove('PHP_FCGI_CHILDREN') };$null=$info.Environment.Remove('PHP_FCGI_CHILDREN_FOR_KID')
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $process=[Diagnostics.Process]::Start($info)
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    try {
        while ($timer.Elapsed.TotalSeconds -lt 30) {
            if ($process.HasExited) { throw "Cache owner exited before readiness: $($process.ExitCode); $($stderr.GetAwaiter().GetResult())" }
            $socket=[Net.Sockets.TcpClient]::new()
            try {
                $connect=$socket.ConnectAsync('127.0.0.1',$port)
                if ($connect.Wait(200) -and $socket.Connected) {
                    # php-cgi binds only after php_module_startup and OPcache startup complete.
                    if ($Children) {
                        $workers=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id)" | Where-Object { $_.Name -eq 'php-cgi.exe' })
                        if ($workers.Count -ne $Children) { continue }
                    }
                    $timer.Stop()
                    return [pscustomobject]@{Process=$process;Port=$port;Children=$Children;ReadyMilliseconds=$timer.Elapsed.TotalMilliseconds;Stdout=$stdout;Stderr=$stderr;Report=$Report}
                }
            } catch { } finally { $socket.Dispose() }
            Start-Sleep -Milliseconds 10
        }
        throw 'Cache owner did not become ready'
    } catch {
        if (-not $process.HasExited) { $process.Kill();$process.WaitForExit() }
        $process.Dispose();throw
    }
}
function Stop-CacheOwner {
    param([Parameter(Mandatory)]$Owner)
    $p=$Owner.Process;$p.Refresh()
    $record=@{pid=$p.Id;port=$Owner.Port;children=$Owner.Children;readyMilliseconds=$Owner.ReadyMilliseconds;exitedUnexpectedly=$p.HasExited}
    if (-not $p.HasExited) {
        $record.cpuSeconds=$p.TotalProcessorTime.TotalSeconds
        $record.workingSetBytes=$p.WorkingSet64
        $p.Kill();$p.WaitForExit()
    }
    $Owner.Stdout.GetAwaiter().GetResult() | Set-Content "$($Owner.Report).stdout.txt"
    $Owner.Stderr.GetAwaiter().GetResult() | Set-Content "$($Owner.Report).stderr.txt"
    $p.Dispose()
    return $record
}
