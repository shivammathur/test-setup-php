param([Parameter(Mandatory)][string]$Branch, [string]$Arch='x64', [string]$Ts='ts', [ValidateSet('cgi','cli-server')][string]$Suite='cgi')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$root=(Get-Location).Path
$manifest=Get-Content manifest.json -Raw | ConvertFrom-Json -AsHashtable
$entry=$manifest.branches[$Branch]
$runtime=@($entry.php.GetEnumerator() | Where-Object { $_.Value.arch -eq $Arch -and $_.Value.ts -eq $Ts })
if ($runtime.Count -ne 1) { throw 'Ambiguous PHP runtime' }
$archive=Join-Path artifacts $runtime[0].Key
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $runtime[0].Value.sha256) { throw 'PHP runtime hash mismatch' }
if ((git -C source rev-parse HEAD).Trim() -ne $entry.sourceSha) { throw 'Source SHA mismatch' }
$phpRoot=Join-Path $env:RUNNER_TEMP 'cgi-diagnosis'
Expand-Archive $archive $phpRoot -Force
$php=Join-Path $phpRoot 'php.exe'
$cgi=Join-Path $phpRoot 'php-cgi.exe'
$env:PATH="$phpRoot;$env:PATH"
$env:TEST_PHP_EXECUTABLE=$php
$env:TEST_PHP_CGI_EXECUTABLE=$cgi
$env:TEST_PHPDBG_EXECUTABLE=Join-Path $phpRoot 'phpdbg.exe'
$env:NO_INTERACTION='1';$env:REPORT_EXIT_STATUS='1';$env:SKIP_IO_CAPTURE_TESTS='1'
$reports=(New-Item reports -ItemType Directory -Force).FullName
$env:STARTUP_DIAGNOSTIC_LOG=Join-Path $reports 'process-exits.jsonl'
$originals=@{}
$testFiles=if ($Suite -eq 'cgi') { @(Get-ChildItem source/sapi/cgi/tests -Filter '*.phpt') } else { @(Get-ChildItem source/sapi/cli/tests -Filter 'php_cli_server*.phpt') }
foreach ($file in $testFiles) {
    $originals[$file.FullName]=[IO.File]::ReadAllText($file.FullName)
}
$runner=(Resolve-Path source/run-tests.php).Path
$originals[$runner]=[IO.File]::ReadAllText($runner)
$serverHelper=(Resolve-Path source/sapi/cli/tests/php_cli_server.inc).Path
$originals[$serverHelper]=[IO.File]::ReadAllText($serverHelper)
# run-tests.php and the built-in-server helper suppress child fault reporting.
# Preserve runtime behavior while allowing the already-verified debugger to run.
foreach ($file in @($runner,$serverHelper)) {
    if (-not ($originals[$file].Contains("'suppress_errors' => true") -or $originals[$file].Contains('"suppress_errors" => true'))) { throw 'Fault-reporting option has changed' }
    $diagnostic=$originals[$file].Replace("'suppress_errors' => true","'suppress_errors' => false").Replace('"suppress_errors" => true','"suppress_errors" => false')
    if ($file -eq $serverHelper) {
        $needle='$status = proc_get_status($handle);'
        $position=$diagnostic.IndexOf($needle)
        if ($position -lt 0) { throw 'Server startup status check has changed' }
        $trace='$status = proc_get_status($handle); if (!$status["running"]) { file_put_contents(getenv("STARTUP_DIAGNOSTIC_LOG"), json_encode(["status"=>$status,"command"=>$cmd,"output"=>file_get_contents($output_file)])."\n", FILE_APPEND); }'
        $diagnostic=$diagnostic.Substring(0,$position)+$trace+$diagnostic.Substring($position+$needle.Length)
    }
    [IO.File]::WriteAllText($file,$diagnostic)
}
git -C source diff | Set-Content reports/fault-reporting.patch
$testArguments=if ($Suite -eq 'cgi') { @('sapi/cgi/tests') } else { @($testFiles | ForEach-Object { 'sapi/cli/tests/'+$_.Name }) }
$trials=[Collections.Generic.List[object]]::new()
try {
    foreach ($mode in 'default','disabled') {
        if ($mode -eq 'disabled') {
            # The reviewed CGI PHPTs start child processes with -n. Disable their
            # built-in OPcache explicitly without changing executable-path quoting.
            foreach ($file in $testFiles) {
                $changed=[regex]::Replace($originals[$file.FullName],'(?ms)(^--FILE--\r?\n)(.*?)(?=^--[A-Z_]+--)',[Text.RegularExpressions.MatchEvaluator]{
                    param($match)
                    $match.Groups[1].Value+$match.Groups[2].Value.Replace(' -n',' -n -d opcache.enable=0')
                })
                [IO.File]::WriteAllText($file.FullName,$changed)
            }
            $helper=[IO.File]::ReadAllText($serverHelper)
            if (-not $helper.Contains("'-n', ...`$cmd_args")) { throw 'Server helper arguments have changed' }
            [IO.File]::WriteAllText($serverHelper,$helper.Replace("'-n', ...`$cmd_args","'-n', '-d', 'opcache.enable=0', ...`$cmd_args"))
            git -C source diff | Set-Content reports/control.patch
        }
        for ($trial=0;$trial -lt 6;$trial++) {
            $env:TEST_PHP_JUNIT=Join-Path $reports "$mode-$trial.xml"
            $log=Join-Path $reports "$mode-$trial.log"
            $settings=@('-d','opcache.enable_cli=0')
            if ($mode -eq 'disabled') { $settings+=@('-d','opcache.enable=0') }
            Push-Location source
            try {
                & $php -n run-tests.php -p $php -n @settings --offline --show-diff --set-timeout 60 -q -j6 @testArguments *> $log
                $exitCode=$LASTEXITCODE
            } finally { Pop-Location }
            if (-not (Test-Path $env:TEST_PHP_JUNIT)) { throw 'CGI suite did not produce JUnit' }
            $trials.Add(@{mode=$mode;trial=$trial;exitCode=$exitCode;report="$mode-$trial.xml";dumps=@(Get-ChildItem dumps -Filter '*.dmp').Count})
            Write-Host "$mode trial $trial exit=$exitCode dumps=$(@(Get-ChildItem dumps -Filter '*.dmp').Count)"
        }
    }
} finally {
    foreach ($file in $originals.GetEnumerator()) { [IO.File]::WriteAllText($file.Key,$file.Value) }
    @{branch=$Branch;suite=$Suite;sourceSha=$entry.sourceSha;phpRun=$entry.run;runtime=$runtime[0].Key;sha256=$runtime[0].Value.sha256;arch=$Arch;ts=$Ts;trials=$trials.ToArray()} |
        ConvertTo-Json -Depth 6 | Set-Content reports/diagnosis.json
}
# This workflow collects diagnostic outcomes; PHPT failures are retained above.
exit 0
