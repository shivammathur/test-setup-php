param(
    [Parameter(Mandatory)] [string] $Branch,
    [Parameter(Mandatory)] [ValidateSet('x86','x64')] [string] $Arch,
    [Parameter(Mandatory)] [ValidateSet('baseline','fixed')] [string] $Flavor
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$entries = @(Get-Content debug-manifest.json -Raw | ConvertFrom-Json | Where-Object { $_.branch -eq $Branch -and $_.arch -eq $Arch -and $_.flavor -eq $Flavor })
if ($entries.Count -ne 1) { throw 'Ambiguous artifact selection' }
$entry = $entries[0]
$report = (New-Item reports -ItemType Directory -Force).FullName
$phpRoot = Join-Path $env:RUNNER_TEMP 'race-php'
$symbols = Join-Path $env:RUNNER_TEMP 'race-symbols'
foreach ($item in @(@{name=$entry.runtime; sha=$entry.runtimeSha256; destination=$phpRoot}, @{name=$entry.debugPack; sha=$entry.debugSha256; destination=$symbols})) {
    $zip = Join-Path "$root/artifacts" $item.name
    if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.sha) { throw "Archive checksum mismatch: $($item.name)" }
    Expand-Archive $zip $item.destination -Force
}
$entry | ConvertTo-Json -Depth 6 | Set-Content "$report/provenance.json"
$php = Join-Path $phpRoot 'php-cgi.exe'
$env:PATH = "$phpRoot;$env:PATH"
$cdb = Join-Path ${env:ProgramFiles(x86)} "Windows Kits/10/Debuggers/$Arch/cdb.exe"
$symbolPath = "$symbols;$phpRoot;srv*$env:RUNNER_TEMP/microsoft-symbols*https://msdl.microsoft.com/download/symbols"
$module = if (Test-Path "$phpRoot/ext/php_opcache.dll") { 'php_opcache' } else { 'php8' }
$fixture = Join-Path $report 'startup.php'
'<?php $s=opcache_get_status(false); if (!$s || !$s["opcache_enabled"]) exit(1); echo "CGI_STARTUP_OK"; usleep(3000000);' | Set-Content $fixture
$source = Get-Content source/ext/opcache/ZendAccelerator.c
$postStartupLine = @(for ($i=0; $i -lt $source.Count; $i++) { if ($source[$i] -match '^static zend_result accel_post_startup\(void\)$') { $i } })
if ($postStartupLine.Count -ne 1) { throw 'Cannot locate startup function' }
$phases = @(
    @{name='shared-globals'; pattern='if (zend_accel_init_shm() == FAILURE)'},
    @{name='jit-buffer'; pattern='ZCG(last_restart_time) = ZCSG(last_restart_time);'}
)
function Start-Debugger([string] $Label, [string] $Commands, [string[]] $PhpArguments) {
    $commandFile = Join-Path $report "$Label.commands.txt"
    $log = Join-Path $report "$Label.log"
    $Commands | Set-Content $commandFile
    $info = [Diagnostics.ProcessStartInfo]::new($cdb)
    $info.UseShellExecute=$false
    $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($key in @($info.Environment.Keys)) {
        if ($key -match '(?i)TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTHORIZATION') { $null=$info.Environment.Remove($key) }
    }
    foreach ($argument in @('-hd','-G','-y',$symbolPath,'-srcpath',"$root/source",'-logo',$log,'-cf',$commandFile,$php) + $PhpArguments) { $info.ArgumentList.Add($argument) }
    $p=[Diagnostics.Process]::new(); $p.StartInfo=$info; $null=$p.Start()
    return @{process=$p; log=$log; stdout=$p.StandardOutput.ReadToEndAsync(); stderr=$p.StandardError.ReadToEndAsync()}
}
function Wait-Marker($Item, [string] $Marker) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 90) {
        if ((Test-Path $Item.log) -and (Get-Content $Item.log -Raw) -match "(?m)^$Marker\r?$") { return }
        if ($Item.process.HasExited) { throw "Debugger exited before $Marker; inspect $($Item.log)" }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $Marker; inspect $($Item.log)"
}
function Finish-Debugger($Item) {
    if (-not $Item.process.WaitForExit(90000)) { throw "Debugger did not exit: $($Item.log)" }
    $text=$Item.stdout.GetAwaiter().GetResult()+$Item.stderr.GetAwaiter().GetResult()
    $text | Set-Content ($Item.log+'.stdout.txt')
    return $text
}
$results=[Collections.Generic.List[object]]::new()
foreach ($phase in $phases) {
    $creator=$null; $peer=$null
    $result=@{phase=$phase.name; flavor=$Flavor; passed=$false}
    try {
        $lines=@(for ($i=$postStartupLine[0]; $i -lt $source.Count; $i++) { if ($source[$i].Contains($phase.pattern)) { $i+1 } })
        if ($lines.Count -ne 1) { throw "Ambiguous source breakpoint: $($phase.pattern)" }
        $result.sourceLine=$lines[0]
        $arguments=@('-n','-d',"extension_dir=$phpRoot/ext",'-d','extension=zend_test','-d','opcache.enable_cli=1','-d',"opcache.cache_id=race-$([guid]::NewGuid())",'-d','opcache.jit=tracing','-d','opcache.jit_buffer_size=64M')
        if ($module -eq 'php_opcache') { $arguments+=@('-d','zend_extension=opcache') }
        $arguments+=@($fixture)
        $creatorCommands='.symopt+0x410; .lines -e; dx @$debuggerRootNamespace.Debugger.Settings.EngineInitialization.ResolveAmbiguousBreakpoints = true; bu /1 '+$module+'!accel_post_startup ".echo POST_STARTUP;"; g'
        $creator=Start-Debugger ($phase.name+'-creator') $creatorCommands $arguments
        Wait-Marker $creator 'POST_STARTUP'
        # The lock helper can have many inline instances in optimized builds.
        # Select the exact startup call site using the matching source and PDB.
        $location='`'+$module+'!ZendAccelerator.c:'+$lines[0]+'`'
        $breakpoint='bp /1 '+$location+' ".echo CREATOR_PAUSED; kv; ?? '+$module+'!smm_shared_globals; ?? '+$module+'!accel_shared_globals;"; g'
        $creator.process.StandardInput.WriteLine($breakpoint); $creator.process.StandardInput.Flush()
        Wait-Marker $creator 'CREATOR_PAUSED'
        # Optimized x86 line tables can point at the preceding unlock call.
        $creator.process.StandardInput.WriteLine('u @$ip L1; .echo INSTRUCTION_READY'); $creator.process.StandardInput.Flush()
        Wait-Marker $creator 'INSTRUCTION_READY'
        $creatorLog=Get-Content $creator.log -Raw
        if ($phase.name -eq 'shared-globals' -and $creatorLog -notmatch 'struct _zend_accel_shared_globals \* 0x0+(?:`0+)?\r?\n') { throw 'Creator has already initialized shared globals' }
        if ($phase.name -eq 'jit-buffer' -and $creatorLog -match '(?m)^.*\bcall\s+\w+!zend_shared_alloc_unlock\b[^\r\n]*\r?\nINSTRUCTION_READY') {
            $creator.process.StandardInput.WriteLine('p; .echo INNER_LOCK_RELEASED'); $creator.process.StandardInput.Flush()
            Wait-Marker $creator 'INNER_LOCK_RELEASED'
        }
        $dump=(Join-Path $report ($phase.name+'.dmp')).Replace('\','/')
        $peerCommands='.symopt+0x410; sxd -c2 ".echo PEER_CRASHED; .dump /m '+$dump+'; .exr -1; r; kv; ?? '+$module+'!smm_shared_globals; ?? '+$module+'!accel_shared_globals; ?? '+$module+'!dasm_ptr; q" av; bu /1 '+$module+'!accel_post_startup ".echo PEER_STARTING; gc"; g'
        $peer=Start-Debugger ($phase.name+'-peer') $peerCommands $arguments
        Wait-Marker $peer 'PEER_STARTING'
        if ($Flavor -eq 'baseline') {
            $peerText=Finish-Debugger $peer
            $expectedFrame=if ($phase.name -eq 'shared-globals') { 'accel_post_startup' } else { 'dasm_encode' }
            $result.reproduced=$peerText -match '(?m)^PEER_CRASHED\r?$' -and $peerText.Contains($expectedFrame) -and (Test-Path $dump)
            $result.expectedFrame=$expectedFrame
            if (-not $result.reproduced) { throw "Baseline did not reproduce $expectedFrame" }
        } else {
            Start-Sleep -Seconds 2
            if ($peer.process.HasExited) { throw 'Peer completed before creator initialized shared memory' }
            $result.peerWaited=$true
        }
        $creator.process.StandardInput.WriteLine('bc *; g'); $creator.process.StandardInput.Flush()
        $creatorText=Finish-Debugger $creator
        if (-not $creatorText.Contains('CGI_STARTUP_OK') -or $creatorText -match 'Access violation - code') { throw 'Creator failed after resuming' }
        if ($Flavor -eq 'fixed') {
            $peerText=Finish-Debugger $peer
            if (-not $peerText.Contains('CGI_STARTUP_OK') -or $peerText -match '(?m)^PEER_CRASHED\r?$|Access violation - code') { throw 'Peer failed after creator resumed' }
        }
        $result.passed=$true
        Write-Host "PASS $Flavor $($phase.name) $Branch $Arch"
    } catch {
        $result.error=$_.Exception.Message
        Write-Host "::error::$($result.error)"
    } finally {
        foreach ($item in @($creator,$peer)) {
            if ($null -eq $item) { continue }
            if (-not $item.process.HasExited) { $item.process.Kill($true); $item.process.WaitForExit() }
            $item.process.Dispose()
        }
        $results.Add($result)
        $results | ConvertTo-Json -Depth 6 | Set-Content "$report/summary.json"
    }
}
if (@($results | Where-Object { -not $_.passed }).Count) { throw 'Startup race validation failed' }
