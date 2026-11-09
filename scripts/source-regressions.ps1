param([Parameter(Mandatory)] [string] $Branch)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = (Get-Location).Path
$manifest = Get-Content manifest.json -Raw | ConvertFrom-Json -AsHashtable
$entry = $manifest.branches[$Branch]
$report = New-Item reports -ItemType Directory -Force
$cases = [Collections.Generic.List[object]]::new()
$testsRoot = (Resolve-Path source).Path
$selected = @('Zend/tests/record_errors_001.phpt', 'ext/standard/tests/ini_info/php_ini_loaded_file.phpt', 'sapi/cgi/tests/006.phpt', 'sapi/cgi/tests/011.phpt')
$available = @($selected | Where-Object { Test-Path (Join-Path $testsRoot $_) })
foreach ($file in $entry.php.GetEnumerator()) {
    $zip = Join-Path "$root/artifacts" $file.Key
    if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.Value.sha256) { throw 'PHP archive hash mismatch' }
    $variant = "$($file.Value.arch)-$($file.Value.ts)"
    $phpRoot = Join-Path $env:RUNNER_TEMP "focused-$variant"
    Expand-Archive $zip $phpRoot -Force
    $php = Join-Path $phpRoot 'php.exe'
    $env:PATH = "$phpRoot;$env:PATH"
    $env:TEST_PHP_EXECUTABLE = $php
    $env:TEST_PHPDBG_EXECUTABLE = Join-Path $phpRoot 'phpdbg.exe'
    $env:TEST_PHP_CGI_EXECUTABLE = Join-Path $phpRoot 'php-cgi.exe'
    $env:NO_INTERACTION = 1
    $env:REPORT_EXIT_STATUS = 1
    Push-Location $testsRoot
    try {
        foreach ($cache in 'nocache', 'opcache') {
            $settings = @('-d', "extension_dir=$phpRoot/ext", '-d', 'extension=zend_test')
            if ($cache -eq 'opcache') {
                if (Test-Path "$phpRoot/ext/php_opcache.dll") { $settings += @('-d', 'zend_extension=opcache') }
                $settings += @('-d', 'opcache.enable_cli=1', '-d', 'opcache.jit_buffer_size=64M', '-d', 'opcache.jit=tracing', '-d', 'opcache.record_warnings=1')
            } else { $settings += @('-d', 'opcache.enable_cli=0') }
            $systemIdTest = Join-Path $testsRoot 'ext/zend_test/tests/system_id_reinitialization.phpt'
            if (Test-Path $systemIdTest) {
                # run-tests.php incorrectly probes phpdbg extensions through CLI with phpdbg's -rr option.
                # Execute the upstream FILE/PHPDBG sections directly, with its required INI setting.
                $phpt = Get-Content $systemIdTest -Raw
                $fixture = [regex]::Match($phpt, '(?s)--FILE--\r?\n(.*?)--EXPECTF--').Groups[1].Value
                $commands = [regex]::Match($phpt, '(?s)--PHPDBG--\r?\n(.*?)--FILE--').Groups[1].Value
                $fixturePath = Join-Path $report.FullName "$variant-$cache-system-id.php"
                $fixture | Set-Content $fixturePath
                $probe = & $php -n @settings -d zend_test.register_system_entropy=1 -r 'echo json_encode([extension_loaded("zend_test"), ini_get("zend_test.register_system_entropy")]);'
                if ($LASTEXITCODE -ne 0 -or ($probe -join '').Trim() -ne '[true,"1"]') { throw "zend_test did not load correctly: $probe" }
                $phpdbg = Join-Path $phpRoot 'phpdbg.exe'
                $output = $commands | & $phpdbg -n -qIb @settings -d zend_test.register_system_entropy=1 $fixturePath 2>&1 | Out-String
                $code = $LASTEXITCODE
                $output | Set-Content (Join-Path $report.FullName "$variant-$cache-system-id.log")
                $runs = [regex]::Matches($output, '(?m)^prompt> Done\r?$').Count
                $passed = $code -eq 0 -and $runs -eq 3 -and $output -notmatch '(?i)failed to register system entropy|warning:|fatal error|parse error'
                $cases.Add(@{ label="$variant-$cache-system-id"; exitCode=$(if ($passed) {0} else {1}); runs=$runs; extensionProbe=$probe; upstreamFixtureSha256=(Get-FileHash $systemIdTest -Algorithm SHA256).Hash })
            }
            if ($file.Value.ts -eq 'nts' -and $cache -eq 'opcache') {
                $cgiFixture = Join-Path $report.FullName "$variant-cgi-startup.php"
                '<?php header("Content-Type: text/plain"); echo "CGI_STARTUP_OK";' | Set-Content $cgiFixture
                $launches = [Collections.Generic.List[object]]::new()
                for ($batch=0; $batch -lt 8; $batch++) {
                    $processes = @(1..64 | ForEach-Object {
                        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $phpRoot 'php-cgi.exe'))
                        $start.UseShellExecute = $false
                        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
                        foreach ($argument in @('-n') + $settings + @($cgiFixture)) { $start.ArgumentList.Add($argument) }
                        $process = [Diagnostics.Process]::new(); $process.StartInfo=$start
                        $null=$process.Start()
                        @{ process=$process; stdout=$process.StandardOutput.ReadToEndAsync(); stderr=$process.StandardError.ReadToEndAsync() }
                    })
                    foreach ($item in $processes) {
                        $process=$item.process
                        if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit() }
                        $stdout=$item.stdout.GetAwaiter().GetResult(); $stderr=$item.stderr.GetAwaiter().GetResult()
                        $launches.Add(@{ pid=$process.Id; exitCode=$process.ExitCode; passed=($process.ExitCode -eq 0 -and $stdout.Contains('CGI_STARTUP_OK')); stdout=$stdout; stderr=$stderr })
                        $process.Dispose()
                    }
                }
                $launches | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $report.FullName "$variant-cgi-startup.json")
                $bad = @($launches | Where-Object { -not $_.passed }).Count
                $cases.Add(@{ label="$variant-cgi-startup"; exitCode=$(if ($bad) {1} else {0}); passed=($launches.Count-$bad); failed=$bad; total=$launches.Count })
            }
            $label = "$variant-$cache"
            $env:TEST_PHP_JUNIT = Join-Path $report.FullName "$label.xml"
            # Pass INI settings individually: a forced -c contaminates php_ini_loaded_file's -n subprocess.
            & $php -n run-tests.php -p $php -n @settings --offline --show-diff -q @available *> (Join-Path $report.FullName "$label.log")
            $code = $LASTEXITCODE
            $cases.Add(@{ label=$label; exitCode=$code; tests=$available; sha256=$file.Value.sha256 })
            # Repeat the two CGI tests serially to distinguish intermittent subprocess failures.
            for ($attempt=1; $attempt -le 5; $attempt++) {
                $env:TEST_PHP_JUNIT = Join-Path $report.FullName "$label-cgi-$attempt.xml"
                & $php -n run-tests.php -p $php -n @settings --offline --show-diff -q sapi/cgi/tests/006.phpt sapi/cgi/tests/011.phpt *> (Join-Path $report.FullName "$label-cgi-$attempt.log")
                $cases.Add(@{ label="$label-cgi-$attempt"; exitCode=$LASTEXITCODE; tests=@('sapi/cgi/tests/006.phpt','sapi/cgi/tests/011.phpt') })
            }
        }
    } finally { Pop-Location }
}
$cases | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $report.FullName 'summary.json')
if (@($cases | Where-Object { $_.exitCode -ne 0 }).Count) { throw 'Focused source tests failed; inspect JUnit and logs' }
