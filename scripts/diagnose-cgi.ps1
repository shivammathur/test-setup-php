param([Parameter(Mandatory)][string]$Branch, [string]$Arch='x64', [string]$Ts='ts')
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
$originals=@{}
foreach ($file in Get-ChildItem source/sapi/cgi/tests -Filter '*.phpt') {
    $originals[$file.FullName]=[IO.File]::ReadAllText($file.FullName)
}
$trials=[Collections.Generic.List[object]]::new()
try {
    foreach ($mode in 'default','disabled') {
        if ($mode -eq 'disabled') {
            # The reviewed CGI PHPTs start child processes with -n. Disable their
            # built-in OPcache explicitly without changing executable-path quoting.
            foreach ($file in $originals.GetEnumerator()) {
                $changed=[regex]::Replace($file.Value,'(?ms)(^--FILE--\r?\n)(.*?)(?=^--[A-Z_]+--)',[Text.RegularExpressions.MatchEvaluator]{
                    param($match)
                    $match.Groups[1].Value+$match.Groups[2].Value.Replace(' -n',' -n -d opcache.enable=0')
                })
                [IO.File]::WriteAllText($file.Key,$changed)
            }
            git -C source diff -- sapi/cgi/tests | Set-Content reports/control.patch
        }
        for ($trial=0;$trial -lt 6;$trial++) {
            $env:TEST_PHP_JUNIT=Join-Path $reports "$mode-$trial.xml"
            $log=Join-Path $reports "$mode-$trial.log"
            $settings=@('-d','opcache.enable_cli=0')
            if ($mode -eq 'disabled') { $settings+=@('-d','opcache.enable=0') }
            Push-Location source
            try {
                & $php -n run-tests.php -p $php -n @settings --offline --show-diff --set-timeout 60 -q -j6 sapi/cgi/tests *> $log
                $exitCode=$LASTEXITCODE
            } finally { Pop-Location }
            if (-not (Test-Path $env:TEST_PHP_JUNIT)) { throw 'CGI suite did not produce JUnit' }
            $trials.Add(@{mode=$mode;trial=$trial;exitCode=$exitCode;report="$mode-$trial.xml";dumps=@(Get-ChildItem dumps -Filter '*.dmp').Count})
            Write-Host "$mode trial $trial exit=$exitCode dumps=$(@(Get-ChildItem dumps -Filter '*.dmp').Count)"
        }
    }
} finally {
    foreach ($file in $originals.GetEnumerator()) { [IO.File]::WriteAllText($file.Key,$file.Value) }
    @{branch=$Branch;sourceSha=$entry.sourceSha;phpRun=$entry.run;runtime=$runtime[0].Key;sha256=$runtime[0].Value.sha256;arch=$Arch;ts=$Ts;trials=$trials.ToArray()} |
        ConvertTo-Json -Depth 6 | Set-Content reports/diagnosis.json
}
