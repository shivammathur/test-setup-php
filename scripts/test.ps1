param(
    [Parameter(Mandatory)][string] $Php,
    [Parameter(Mandatory)][string] $Label,
    [Parameter(Mandatory)][ValidateSet('x64', 'x86')][string] $Arch,
    [Parameter(Mandatory)][ValidateSet('ts', 'nts')][string] $Ts,
    [switch] $ExpectBug
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Join-Path $env:RUNNER_TEMP "gh25213-$Label"
$results = Join-Path (Get-Location) "results/$Label"
New-Item -ItemType Directory -Force $root, $results | Out-Null
$Php = (Resolve-Path $Php).Path
$dll = Join-Path (Split-Path $Php) 'ext/php_opcache.dll'
if (!(Test-Path $dll)) { throw 'Missing PHP 8.4 OPcache DLL' }
$common = @('-n', '-d', "zend_extension=$dll", '-d', 'opcache.enable_cli=1',
    '-d', 'opcache.memory_consumption=16', '-d', 'opcache.interned_strings_buffer=1',
    '-d', 'opcache.file_update_protection=0', '-d', 'opcache.max_accelerated_files=20000',
    '-d', 'memory_limit=512M')
function Start-Php([string[]] $Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Php
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    return @{ Process=$process; Out=$process.StandardOutput.ReadToEndAsync(); Err=$process.StandardError.ReadToEndAsync() }
}
function Finish-Php($Child, [string] $Name) {
    if (!$Child.Process.WaitForExit(120000)) {
        $Child.Process.Kill($true)
        throw "$Name timed out"
    }
    $stdout = $Child.Out.GetAwaiter().GetResult()
    $stderr = $Child.Err.GetAwaiter().GetResult()
    $exit = $Child.Process.ExitCode
    $hex = '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$exit), 0)
    $stdout | Set-Content "$results/$Name.stdout.txt"
    $stderr | Set-Content "$results/$Name.stderr.txt"
    $Child.Process.Dispose()
    return @{ Exit=$exit; Hex=$hex; Out=$stdout; Err=$stderr }
}
$records = @()
$failures = @()
foreach ($reattach in @($false, $true)) {
    foreach ($mode in @('tracing', 'off', 'disable', 'zero-buffer')) {
        $name = "$mode-$(if ($reattach) { 'reattach' } else { 'fresh' })"
        $case = Join-Path $root $name
        New-Item -ItemType Directory -Force $case | Out-Null
        $jit = if ($mode -eq 'zero-buffer') { 'tracing' } else { $mode }
        $size = if ($mode -eq 'zero-buffer') { '0' } else { '64M' }
        $arguments = $common + @('-d', "opcache.jit=$jit", '-d', "opcache.jit_buffer_size=$size")
        $holder = $null
        try {
            $marker = ''
            if ($reattach) {
                $marker = Join-Path $case 'marker.php'
                '<?php function gh25213_marker() { return 25213; }' | Set-Content $marker
                $ready = Join-Path $case 'ready'
                $stop = Join-Path $case 'stop'
                $holder = Start-Php ($arguments + @("$PSScriptRoot/holder.php", $marker, $ready, $stop))
                $deadline = [DateTime]::UtcNow.AddSeconds(20)
                while (!(Test-Path $ready) -and !$holder.Process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 100
                }
                if (!(Test-Path $ready)) { throw 'Holder did not become ready' }
            }
            $child = Start-Php ($arguments + @("$PSScriptRoot/fill.php", (Join-Path $case 'fill'), $marker))
            $run = Finish-Php $child $name
            $startLine = @($run.Out -split '\r?\n' | Where-Object { $_.StartsWith('START ') })
            if ($startLine.Count -ne 1) { throw "Missing startup evidence; exit=$($run.Hex) stderr=$($run.Err)" }
            $info = $startLine[0].Substring(6) | ConvertFrom-Json
            $bits = if ($Arch -eq 'x64') { 64 } else { 32 }
            if ($info.bits -ne $bits -or [bool]$info.zts -ne ($Ts -eq 'ts') -or !$info.version.StartsWith('8.4.')) {
                throw "Unexpected runtime identity: $($startLine[0])"
            }
            if ($mode -in @('tracing', 'off')) {
                if (!$info.jit.enabled -or $info.jit.buffer_size -lt 60000000 -or [bool]$info.jit.on -ne ($mode -eq 'tracing')) {
                    throw "JIT configuration did not take effect: $($startLine[0])"
                }
            } elseif ($info.jit.enabled) {
                throw "JIT was not disabled for the control: $($startLine[0])"
            }
            $shouldCrash = $ExpectBug -and $mode -in @('tracing', 'off')
            if ($shouldCrash) {
                if ($run.Hex -ne '0xC0000005' -or $run.Out -notmatch 'PROGRESS ' -or $run.Out -match 'FULL ') {
                    throw "Expected cache-fill access violation, got $($run.Hex)"
                }
            } elseif ($run.Exit -ne 0 -or $run.Out -notmatch '(?m)^FULL ' -or $run.Err.Trim()) {
                throw "Expected clean cache_full, got $($run.Hex); stderr=$($run.Err)"
            }
            $records += [ordered]@{ case=$name; exit=$run.Hex; expected_crash=[bool]$shouldCrash; runtime=$info; passed=$true }
            Write-Host "$Label $Arch $Ts ${name}: $($run.Hex), expected outcome confirmed"
        } catch {
            $failures += "${name}: $_"
            $records += [ordered]@{ case=$name; passed=$false; error="$_" }
            Write-Host "::error::$Label ${name}: $_"
        } finally {
            if ($holder) {
                New-Item -ItemType File -Force $stop | Out-Null
                $holderResult = Finish-Php $holder "$name-holder"
                if ($holderResult.Exit -ne 0 -or $holderResult.Out -notmatch 'HOLDER_DONE') {
                    $failures += "$name holder failed: $($holderResult.Hex)"
                }
            }
            Remove-Item -Recurse -Force $case
        }
    }
}
$records | ConvertTo-Json -Depth 8 | Set-Content "$results/results.json"
"| $Label $Arch $Ts | $($records.Count - $failures.Count)/$($records.Count) |" | Add-Content $env:GITHUB_STEP_SUMMARY
if ($failures.Count) { throw ($failures -join "`n") }
