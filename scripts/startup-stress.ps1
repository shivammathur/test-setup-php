param([Parameter(Mandatory)] [string] $Branch, [Parameter(Mandatory)] [string] $Arch, [Parameter(Mandatory)] [string] $Ts)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$root=(Get-Location).Path
$manifest=Get-Content manifest.json -Raw | ConvertFrom-Json -AsHashtable
$entry=$manifest.branches[$Branch]
$files=@($entry.php.GetEnumerator() | Where-Object { $_.Value.arch -eq $Arch -and $_.Value.ts -eq $Ts })
if ($files.Count -ne 1) { throw 'Ambiguous runtime selection' }
$file=$files[0]
$zip=Join-Path "$root/artifacts" $file.Key
if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.Value.sha256) { throw 'Runtime hash mismatch' }
$phpRoot=Join-Path $env:RUNNER_TEMP 'stress-php'
Expand-Archive $zip $phpRoot -Force
$report=(New-Item reports -ItemType Directory -Force).FullName
$env:PATH="$phpRoot;$env:PATH"
$fixture=Join-Path $report 'startup.php'
'<?php $s=opcache_get_status(false); if (!$s || !$s["opcache_enabled"]) exit(1); if (ini_get("opcache.jit")==="tracing" && !$s["jit"]["on"]) exit(2); echo "STARTUP_OK"; usleep(100000);' | Set-Content $fixture
$settings=@('-n','-d',"extension_dir=$phpRoot/ext",'-d','extension=zend_test','-d','opcache.enable_cli=1','-d','opcache.record_warnings=1')
if (Test-Path "$phpRoot/ext/php_opcache.dll") { $settings+=@('-d','zend_extension=opcache') }
$launches=[Collections.Generic.List[object]]::new()
foreach ($sapi in 'php.exe','php-cgi.exe') {
    foreach ($jit in 'disable','tracing') {
        for ($batch=0; $batch -lt 16; $batch++) {
            $launchArguments=$settings+@('-d',"opcache.cache_id=stress-$([guid]::NewGuid())",'-d',"opcache.jit=$jit",'-d',"opcache.jit_buffer_size=$(if ($jit -eq 'tracing') {'64M'} else {'0'})",$fixture)
            $processes=@(1..32 | ForEach-Object {
                $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $phpRoot $sapi))
                $info.UseShellExecute=$false; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
                foreach ($argument in $launchArguments) { $info.ArgumentList.Add($argument) }
                $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$null=$p.Start()
                @{process=$p;stdout=$p.StandardOutput.ReadToEndAsync();stderr=$p.StandardError.ReadToEndAsync()}
            })
            foreach ($item in $processes) {
                $p=$item.process;$timedOut=-not $p.WaitForExit(30000)
                if ($timedOut) { $p.Kill($true);$p.WaitForExit() }
                $stdout=$item.stdout.GetAwaiter().GetResult();$stderr=$item.stderr.GetAwaiter().GetResult()
                $launches.Add(@{sapi=$sapi;jit=$jit;batch=$batch;exitCode=$p.ExitCode;timedOut=$timedOut;passed=($p.ExitCode -eq 0 -and $stdout.Contains('STARTUP_OK') -and -not $stderr.Trim());stdout=$stdout;stderr=$stderr})
                $p.Dispose()
            }
        }
        Write-Host "$sapi $jit completed"
    }
}
$launches | ConvertTo-Json -Depth 6 | Set-Content "$report/launches.json"
$php=Join-Path $phpRoot 'php.exe'
$env:TEST_PHP_EXECUTABLE=$php
$env:TEST_PHP_CGI_EXECUTABLE=Join-Path $phpRoot 'php-cgi.exe'
$env:TEST_PHPDBG_EXECUTABLE=Join-Path $phpRoot 'phpdbg.exe'
$env:TEST_PHP_JUNIT=Join-Path $report 'opcache.xml'
$env:NO_INTERACTION=1;$env:REPORT_EXIT_STATUS=1
Push-Location source
try {
    & $php -n run-tests.php -p $php @settings -d opcache.jit=tracing -d opcache.jit_buffer_size=64M --offline --show-diff --set-timeout 120 -q -j2 ext/opcache sapi/cgi/tests/006.phpt sapi/cgi/tests/011.phpt ext/standard/tests/ini_info/php_ini_loaded_file.phpt *> "$report/opcache.log"
    $testExit=$LASTEXITCODE
} finally { Pop-Location }
$bad=@($launches | Where-Object { -not $_.passed })
$summary=@{sourceRun=$entry.run;sourceSha=$entry.sourceSha;runtime=$file.Key;sha256=$file.Value.sha256;launches=$launches.Count;failed=$bad.Count;phptExitCode=$testExit}
$summary | ConvertTo-Json -Depth 5 | Set-Content "$report/summary.json"
if ($bad.Count -or $testExit -ne 0) { throw 'Concurrent startup or OPcache regression tests failed' }
